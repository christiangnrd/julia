# This file is a part of Julia. License is MIT: https://julialang.org/license

"""
An abstract type representing any sort of pattern matching expression
(typically a regular expression). `AbstractPattern` objects can be used to
match strings with [`match`](@ref).

!!! compat "Julia 1.6"
    This type is available in Julia 1.6 and later.
"""
abstract type AbstractPattern end

# TODO: These unions represent bytes in memory that can be accessed via a pointer.
# this property is used throughout Julia, e.g. also in IO code.
# This deserves a better solution - see #53178.
# If such a better solution comes in place, these unions should be replaced.
const DenseInt8 = Union{
    DenseArray{Int8},
    FastContiguousSubArray{Int8,N,<:DenseArray} where N
}

# Note: This union is different from that above in that it includes CodeUnits.
# Currently, this is redundant as CodeUnits <: DenseVector, but this subtyping
# is buggy and may be removed in the future, see #54002
const DenseUInt8 = Union{
    DenseArray{UInt8},
    FastContiguousSubArray{UInt8,N,<:DenseArray} where N,
    CodeUnits{UInt8, <:Union{String, SubString{String}}},
    FastContiguousSubArray{UInt8,N,<:CodeUnits{UInt8, <:Union{String, SubString{String}}}} where N,
}

const DenseUInt8OrInt8 = Union{DenseUInt8, DenseInt8}

function last_utf8_byte(c::Char)
    u = reinterpret(UInt32, c)
    shift = ((4 - ncodeunits(c)) * 8) & 31
    (u >> shift) % UInt8
end

# Whether the given byte is guaranteed to be the only byte in a Char
# This holds even in the presence of invalid UTF8
is_standalone_byte(x::UInt8) = (x < 0x80) | (x > 0xf7)

last_byteindex(x::Union{String, SubString{String}}) = ncodeunits(x)
last_byteindex(x::DenseUInt8OrInt8) = lastindex(x)

# Internal type - lazy iterator over positions of char in string
struct FwCharPosIter{S}
    string::S # S is assumed to be either String or SubString{String}
    char::Char
    # Char searchers search for the last UTF8 byte, because this byte tends to
    # have the most variety in real texts, so any individual value is rarer.
    # This allows more work to be done in the fast path using memchr.
    last_char_byte::UInt8
end

function FwCharPosIter(s::Union{String, SubString{String}}, c::AbstractChar)
    char = Char(c)::Char
    byte = last_utf8_byte(char)
    FwCharPosIter{typeof(s)}(s, char, byte)
end

# i is the index in the string to search from.
# We assume it's never < firstindex(s.string)
function Base.iterate(s::FwCharPosIter, i::Int=1)
    scu = ncodeunits(s.string)

    # By definition, if the last byte is a standalone byte, then the char
    # is a single-byte char where the byte can never be a subset of another char.
    # Hence, we can simply search for the occurrence of the byte itself.
    if is_standalone_byte(s.last_char_byte)
        i > scu && return nothing
        i = _search(s.string, s.last_char_byte, i)
        i === nothing ? nothing : (i, i + 1)
    else
        ncu = ncodeunits(s.char)
        while true
            i > scu && return nothing
            i = _search(s.string, s.last_char_byte, i)
            i === nothing && return nothing
            # Increment i before the continue to avoid infinite loop.
            # Since we search for the last byte in the char, the index has an offset.
            i += 1
            index = i - ncu
            # The byte may be part of a different char, in which case index
            # may be invalid.
            isvalid(s.string, index) || continue
            # Here, we use iterate instead of indexing, because indexing needlessly
            # re-validates the index which we have already done here.
            # This relies on the implementation detail that the iterator state for
            # iterating strings is the same as the byte index.
            char = first(something(iterate(s.string, index)))
            char == s.char && return (index, i)
        end
    end
end

# Internal type - lazy iterator over positions of char in string, in reverse order
struct RvCharPosIter{S}
    string::S # S is assumed to be either String or SubString{String}
    char::Char
    last_char_byte::UInt8
end

IteratorSize(s::Type{<:Union{FwCharPosIter, RvCharPosIter}}) = SizeUnknown()
eltype(::Type{<:Union{FwCharPosIter, RvCharPosIter}}) = Int

function RvCharPosIter(s::Union{String, SubString{String}}, c::AbstractChar)
    char = Char(c)::Char
    byte = last_utf8_byte(char)
    RvCharPosIter{typeof(s)}(s, char, byte)
end

# i is the index in the string to search from
# We assume it's never > ncodeunits(s.string)
# This is the same implementation as FwCharPosIter, except for two differences:
# 1. i must be decremented, not incremented because we are searching backwards
# 2. Because we search for the last byte, the starting value of i need to be
#    incremented in the beginning, as that byte may be found at i + ncodeunits(char) - 1.
function Base.iterate(s::RvCharPosIter, i::Int=ncodeunits(s.string))
    ncu = ncodeunits(s.char)
    if is_standalone_byte(s.last_char_byte)
        i < ncu && return nothing
        i = _rsearch(s.string, s.last_char_byte, i)
        i === nothing ? nothing : (i, i - 1)
    else
        i = min(ncodeunits(s.string), i + ncu - 1)
        while true
            i < ncu && return nothing
            i = _rsearch(s.string, s.last_char_byte, i)
            i === nothing && return nothing
            index = i - ncu + 1
            i -= 1
            isvalid(s.string, index) || continue
            char = first(something(iterate(s.string, index)))
            char == s.char && return (index, i)
        end
    end
end

function try_next(x, state)
    y = iterate(x, state)
    y === nothing ? nothing : first(y)
end

function findnext(
    pred::Fix2{<:Union{typeof(isequal),typeof(==)},<:AbstractChar},
    s::Union{String, SubString{String}},
    i::Integer,
)
    # TODO: Redesign these strange rules for errors, see #54584
    scu = ncodeunits(s)
    i == scu + 1 && return nothing
    @boundscheck if i < 1 || i > scu + 1
        throw(BoundsError(s, i))
    end
    # The most common case is probably searching for an ASCII char.
    # We inline this critical path here to avoid instantiating a
    # FwCharPosIter in the common case.
    c = Char(pred.x)::Char
    u = (reinterpret(UInt32, c) >> 24) % UInt8
    i = Int(i)::Int
    isvalid(s, i) || string_index_err(s, i)
    return if is_standalone_byte(u)
        _search(s, u, i)
    else
        try_next(FwCharPosIter(s, c, last_utf8_byte(c)), i)
    end
end

function findnext(pred::Fix2{<:Union{typeof(isequal),typeof(==)},UInt8}, a::DenseUInt8, i::Integer)
    @boundscheck i < firstindex(a) && throw(BoundsError(a, i))
    i > lastindex(a) && return nothing
    _search(a, pred.x, i)
end

function findnext(pred::Fix2{<:Union{typeof(isequal),typeof(==)},Int8}, a::DenseInt8, i::Integer)
    @boundscheck i < firstindex(a) && throw(BoundsError(a, i))
    i > lastindex(a) && return nothing
    _search(a, pred.x, i)
end

# iszero is special, in that the bitpattern for zero for Int8 and UInt8 is the same,
# so we can use memchr even if we search for an Int8 in an UInt8 array or vice versa
function findnext(::typeof(iszero), a::DenseUInt8OrInt8, i::Integer)
    @boundscheck i < firstindex(a) && throw(BoundsError(a, i))
    i > lastindex(a) && return nothing
    _search(a, zero(UInt8), i)
end

# This is essentially just a wrapper around memchr. i must be inbounds.
function _search(a::Union{String,SubString{String},DenseUInt8OrInt8}, b::Union{Int8,UInt8}, i::Integer = firstindex(a))
    fst = firstindex(a)
    GC.@preserve a begin
        p = pointer(a)
        q = ccall(:memchr, Ptr{UInt8}, (Ptr{UInt8}, Int32, Csize_t), p+i-fst, b, last_byteindex(a) - i + 1)
    end
    return q == C_NULL ? nothing : (q-p+fst) % Int
end

function findprev(
    pred::Fix2{<:Union{typeof(isequal),typeof(==)},<:AbstractChar},
    s::Union{String, SubString{String}},
    i::Integer,
)
    # TODO: Redesign these strange rules for errors, see #54584
    if i == ncodeunits(s) + 1 || i == 0
        return nothing
    end
    @boundscheck if i < 1 || i > ncodeunits(s) + 1
        throw(BoundsError(s, i))
    end
    # Manually inline the fast path if c is ASCII, as we expect it to often be
    c = Char(pred.x)::Char
    u = (reinterpret(UInt32, c) >> 24) % UInt8
    i = Int(i)::Int
    return if is_standalone_byte(u)
        _rsearch(s, u, i)
    else
        try_next(RvCharPosIter(s, c, last_utf8_byte(c)), i)
    end
end

function findprev(pred::Fix2{<:Union{typeof(isequal),typeof(==)},Int8}, a::DenseInt8, i::Integer)
    @boundscheck i > lastindex(a) && throw(BoundsError(a, i))
    i < firstindex(a) && return nothing
    _rsearch(a, pred.x, i)
end

function findprev(pred::Fix2{<:Union{typeof(isequal),typeof(==)},UInt8}, a::DenseUInt8, i::Integer)
    @boundscheck i > lastindex(a) && throw(BoundsError(a, i))
    i < firstindex(a) && return nothing
    _rsearch(a, pred.x, i)
end

# See comments above for findfirst(::typeof(iszero)) methods
function findprev(::typeof(iszero), a::DenseUInt8OrInt8, i::Integer)
    @boundscheck i > lastindex(a) && throw(BoundsError(a, i))
    i < firstindex(a) && return nothing
    _rsearch(a, zero(UInt8), i)
end

# This is essentially just a wrapper around memrchr. i must be inbounds.
function _rsearch(a::Union{String,SubString{String},DenseUInt8OrInt8}, b::Union{Int8,UInt8}, i::Integer = last_byteindex(a))
    fst = firstindex(a)
    GC.@preserve a begin
        p = pointer(a)
        q = ccall(:memrchr, Ptr{UInt8}, (Ptr{UInt8}, Int32, Csize_t), p, b, i-fst+1)
    end
    return q == C_NULL ? nothing : (q-p+fst) % Int
end

function findall(
    pred::Fix2{<:Union{typeof(isequal),typeof(==)},<:AbstractChar},
    s::Union{String, SubString{String}},
)
    iter = FwCharPosIter(s, pred.x)
    return if is_standalone_byte(iter.last_char_byte)
        findall(==(iter.last_char_byte), codeunits(s))
    else
        # It is slightly wasteful that every iteration will check is_standalone_byte
        # again, but this should only be minor overhead in the non-fast path.
        collect(iter)
    end
end

"""
    findfirst(pattern::AbstractString, string::AbstractString)
    findfirst(pattern::AbstractPattern, string::String)

Find the first occurrence of `pattern` in `string`. Equivalent to
[`findnext(pattern, string, firstindex(s))`](@ref).

# Examples
```jldoctest
julia> findfirst("z", "Hello to the world") # returns nothing, but not printed in the REPL

julia> findfirst("Julia", "JuliaLang")
1:5
```
"""
findfirst(pattern::AbstractString, string::AbstractString) =
    findnext(pattern, string, firstindex(string))

"""
    findfirst(ch::AbstractChar, string::AbstractString)

Find the first occurrence of character `ch` in `string`.

!!! compat "Julia 1.3"
    This method requires at least Julia 1.3.

# Examples
```jldoctest
julia> findfirst('a', "happy")
2

julia> findfirst('z', "happy") === nothing
true
```
"""
findfirst(ch::AbstractChar, string::AbstractString) = findfirst(==(ch), string)

"""
    findfirst(pattern::AbstractVector{<:Union{Int8,UInt8}},
              A::AbstractVector{<:Union{Int8,UInt8}})

Find the first occurrence of sequence `pattern` in vector `A`.

!!! compat "Julia 1.6"
    This method requires at least Julia 1.6.

# Examples
```jldoctest
julia> findfirst([0x52, 0x62], [0x40, 0x52, 0x62, 0x63])
2:3
```
"""
findfirst(pattern::AbstractVector{<:Union{Int8,UInt8}},
          A::AbstractVector{<:Union{Int8,UInt8}}) =
    _search(A, pattern, firstindex(A))

# AbstractString implementation of the generic findnext interface
function findnext(testf::Function, s::AbstractString, i::Integer)
    i = Int(i)
    z = ncodeunits(s) + 1
    1 ≤ i ≤ z || throw(BoundsError(s, i))
    @inbounds i == z || isvalid(s, i) || string_index_err(s, i)
    e = lastindex(s)
    while i <= e
        testf(@inbounds s[i]) && return i
        i = @inbounds nextind(s, i)
    end
    return nothing
end

in(c::AbstractChar, s::AbstractString) = (findfirst(isequal(c),s)!==nothing)

function _searchindex(s::Union{AbstractString,DenseUInt8OrInt8},
                      t::Union{AbstractString,AbstractChar,Int8,UInt8},
                      i::Integer)
    sentinel = firstindex(s) - 1
    x = Iterators.peel(t)
    if isnothing(x)
        return firstindex(s) <= i <= nextind(s,lastindex(s))::Int ? i :
               throw(BoundsError(s, i))
    end
    t1, trest = x
    while true
        i = findnext(isequal(t1),s,i)
        if i === nothing return sentinel end
        ii = nextind(s, i)::Int
        a = Iterators.Stateful(trest)
        matched = all(splat(==), zip(SubString(s, ii), a))
        (isempty(a) && matched) && return i
        i = ii
    end
end

_searchindex(s::AbstractString, t::AbstractChar, i::Integer) = something(findnext(isequal(t), s, i), 0)

function _search_bloom_mask(c)
    UInt64(1) << (c & 63)
end

_nthbyte(s::Union{String, SubString{String}}, i) = codeunit(s, i)
_nthbyte(t::AbstractVector, index) = t[index + (firstindex(t)-1)]

function _searchindex(s::Union{String, SubString{String}}, t::Union{String, SubString{String}}, i::Integer)
    # Check for fast case of a single byte
    lastindex(t) == 1 && return something(findnext(isequal(t[1]), s, i), 0)
    _searchindex(codeunits(s), codeunits(t), i)
end

function _searchindex(s::AbstractVector{<:Union{Int8,UInt8}},
                      t::AbstractVector{<:Union{Int8,UInt8}},
                      _i::Integer)
    sentinel = firstindex(s) - 1
    n = length(t)
    m = length(s)
    i = Int(_i) - sentinel
    (i < 1 || i > m+1) && throw(BoundsError(s, _i))

    if n == 0
        return 1 <= i <= m+1 ? max(1, i) : sentinel
    elseif m == 0
        return sentinel
    elseif n == 1
        return something(findnext(isequal(_nthbyte(t,1)), s, i), sentinel)
    end

    w = m - n
    if w < 0 || i - 1 > w
        return sentinel
    end

    bloom_mask = UInt64(0)
    skip = n - 1
    tlast = _nthbyte(t,n)
    for j in 1:n
        bloom_mask |= _search_bloom_mask(_nthbyte(t,j))
        if _nthbyte(t,j) == tlast && j < n
            skip = n - j - 1
        end
    end

    i -= 1
    while i <= w
        if _nthbyte(s,i+n) == tlast
            # check candidate
            j = 0
            while j < n - 1
                if _nthbyte(s,i+j+1) != _nthbyte(t,j+1)
                    break
                end
                j += 1
            end

            # match found
            if j == n - 1
                # restore in case `s` is an OffSetArray
                return i+firstindex(s)
            end

            # no match, try to rule out the next character
            if i < w && bloom_mask & _search_bloom_mask(_nthbyte(s,i+n+1)) == 0
                i += n
            else
                i += skip
            end
        elseif i < w
            if bloom_mask & _search_bloom_mask(_nthbyte(s,i+n+1)) == 0
                i += n
            end
        end
        i += 1
    end

    sentinel
end

function _search(s::Union{AbstractString,AbstractVector{<:Union{Int8,UInt8}}},
                 t::Union{AbstractString,AbstractChar,AbstractVector{<:Union{Int8,UInt8}}},
                 i::Integer)
    idx = _searchindex(s,t,i)
    if isempty(t)
        idx:idx-1
    elseif idx >= firstindex(s)
        idx:(idx + lastindex(t) - 1)
    else
        nothing
    end
end

"""
    findnext(pattern::AbstractString, string::AbstractString, start::Integer)
    findnext(pattern::AbstractPattern, string::String, start::Integer)

Find the next occurrence of `pattern` in `string` starting at position `start`.
`pattern` can be either a string, or a regular expression, in which case `string`
must be of type `String`.

The return value is a range of indices where the matching sequence is found, such that
`s[findnext(x, s, i)] == x`:

`findnext("substring", string, i)` == `start:stop` such that
`string[start:stop] == "substring"` and `i <= start`, or `nothing` if unmatched.

# Examples
```jldoctest
julia> findnext("z", "Hello to the world", 1) === nothing
true

julia> findnext("o", "Hello to the world", 6)
8:8

julia> findnext("Lang", "JuliaLang", 2)
6:9
```
"""
findnext(t::AbstractString, s::AbstractString, start::Integer) = _search(s, t, Int(start))

"""
    findnext(ch::AbstractChar, string::AbstractString, start::Integer)

Find the next occurrence of character `ch` in `string` starting at position `start`.

!!! compat "Julia 1.3"
    This method requires at least Julia 1.3.

# Examples
```jldoctest
julia> findnext('z', "Hello to the world", 1) === nothing
true

julia> findnext('o', "Hello to the world", 6)
8
```
"""
findnext(ch::AbstractChar, string::AbstractString, start::Integer) =
    findnext(==(ch), string, start)

"""
    findnext(pattern::AbstractVector{<:Union{Int8,UInt8}},
             A::AbstractVector{<:Union{Int8,UInt8}},
             start::Integer)

Find the next occurrence of the sequence `pattern` in vector `A` starting at position `start`.

!!! compat "Julia 1.6"
    This method requires at least Julia 1.6.

# Examples
```jldoctest
julia> findnext([0x52, 0x62], [0x52, 0x62, 0x72], 3) === nothing
true

julia> findnext([0x52, 0x62], [0x40, 0x52, 0x62, 0x52, 0x62], 3)
4:5
```
"""
findnext(pattern::AbstractVector{<:Union{Int8,UInt8}},
         A::AbstractVector{<:Union{Int8,UInt8}},
         start::Integer) =
    _search(A, pattern, start)

"""
    findlast(pattern::AbstractString, string::AbstractString)

Find the last occurrence of `pattern` in `string`. Equivalent to
[`findprev(pattern, string, lastindex(string))`](@ref).

# Examples
```jldoctest
julia> findlast("o", "Hello to the world")
15:15

julia> findfirst("Julia", "JuliaLang")
1:5
```
"""
findlast(pattern::AbstractString, string::AbstractString) =
    findprev(pattern, string, lastindex(string))

"""
    findlast(pattern::AbstractVector{<:Union{Int8,UInt8}},
             A::AbstractVector{<:Union{Int8,UInt8}})

Find the last occurrence of `pattern` in array `A`. Equivalent to
[`findprev(pattern, A, lastindex(A))`](@ref).

# Examples
```jldoctest
julia> findlast([0x52, 0x62], [0x52, 0x62, 0x52, 0x62])
3:4
```
"""
findlast(pattern::AbstractVector{<:Union{Int8,UInt8}},
         A::AbstractVector{<:Union{Int8,UInt8}}) =
    findprev(pattern, A, lastindex(A))

"""
    findlast(ch::AbstractChar, string::AbstractString)

Find the last occurrence of character `ch` in `string`.

!!! compat "Julia 1.3"
    This method requires at least Julia 1.3.

# Examples
```jldoctest
julia> findlast('p', "happy")
4

julia> findlast('z', "happy") === nothing
true
```
"""
findlast(ch::AbstractChar, string::AbstractString) = findlast(==(ch), string)

"""
    findall(
        pattern::Union{AbstractString,AbstractPattern},
        string::AbstractString;
        overlap::Bool = false,
    )
    findall(
        pattern::Vector{UInt8},
        A::Vector{UInt8};
        overlap::Bool = false,
    )

Return a `Vector{UnitRange{Int}}` of all the matches for `pattern` in `string`.
Each element of the returned vector is a range of indices where the
matching sequence is found, like the return value of [`findnext`](@ref).

If `overlap=true`, the matching sequences are allowed to overlap indices in the
original string, otherwise they must be from disjoint character ranges.

# Examples
```jldoctest
julia> findall("a", "apple")
1-element Vector{UnitRange{Int64}}:
 1:1

julia> findall("nana", "banana")
1-element Vector{UnitRange{Int64}}:
 3:6

julia> findall("a", "banana")
3-element Vector{UnitRange{Int64}}:
 2:2
 4:4
 6:6

julia> findall(UInt8[1,2], UInt8[1,2,3,1,2])
2-element Vector{UnitRange{Int64}}:
 1:2
 4:5
```

!!! compat "Julia 1.3"
     This method requires at least Julia 1.3.
"""
function findall(t::Union{AbstractString, AbstractPattern, AbstractVector{UInt8}},
                 s::Union{AbstractString, AbstractPattern, AbstractVector{UInt8}},
                 ; overlap::Bool=false)
    found = UnitRange{Int}[]
    i, e = firstindex(s), lastindex(s)
    while true
        r = findnext(t, s, i)
        isnothing(r) && break
        push!(found, r)
        j = overlap || isempty(r) ? first(r) : last(r)
        j > e && break
        @inbounds i = nextind(s, j)
    end
    return found
end

# AbstractString implementation of the generic findprev interface
function findprev(testf::Function, s::AbstractString, i::Integer)
    i = Int(i)
    z = ncodeunits(s) + 1
    0 ≤ i ≤ z || throw(BoundsError(s, i))
    i == z && return nothing
    @inbounds i == 0 || isvalid(s, i) || string_index_err(s, i)
    while i >= 1
        testf(@inbounds s[i]) && return i
        i = @inbounds prevind(s, i)
    end
    return nothing
end

function _rsearchindex(s::AbstractString,
                       t::Union{AbstractString,AbstractChar,Int8,UInt8},
                       i::Integer)
    if isempty(t)
        return 1 <= i <= nextind(s, lastindex(s))::Int ? i :
               throw(BoundsError(s, i))
    end
    t1, trest = Iterators.peel(Iterators.reverse(t))::NTuple{2,Any}
    while true
        i = findprev(isequal(t1), s, i)
        i === nothing && return 0
        ii = prevind(s, i)::Int
        a = Iterators.Stateful(trest)
        b = Iterators.Stateful(Iterators.reverse(
            pairs(SubString(s, 1, ii))))
        matched = all(splat(==), zip(a, (x[2] for x in b)))
        if matched && isempty(a)
            isempty(b) && return firstindex(s)
            return nextind(s, popfirst!(b)[1])::Int
        end
        i = ii
    end
end

function _rsearchindex(s::Union{String, SubString{String}}, t::Union{String, SubString{String}}, i::Integer)
    # Check for fast case of a single byte
    if lastindex(t) == 1
        return something(findprev(isequal(t[1]), s, i), 0)
    elseif lastindex(t) != 0
        j = i ≤ ncodeunits(s) ? nextind(s, i)-1 : i
        return _rsearchindex(codeunits(s), codeunits(t), j)
    elseif i > sizeof(s)
        return 0
    elseif i == 0
        return 1
    else
        return i
    end
end

function _rsearchindex(s::AbstractVector{<:Union{Int8,UInt8}}, t::AbstractVector{<:Union{Int8,UInt8}}, _k::Integer)
    sentinel = firstindex(s) - 1
    n = length(t)
    m = length(s)
    k = Int(_k) - sentinel
    k < 0 && throw(BoundsError(s, _k))

    if n == 0
        return 0 <= k <= m ? max(k, 1) : sentinel
    elseif m == 0
        return sentinel
    elseif n == 1
        return something(findprev(isequal(_nthbyte(t,1)), s, k), sentinel)
    end

    w = m - n
    if w < 0 || k <= 0
        return sentinel
    end

    bloom_mask = UInt64(0)
    skip = n - 1
    tfirst = _nthbyte(t,1)
    for j in n:-1:1
        bloom_mask |= _search_bloom_mask(_nthbyte(t,j))
        if _nthbyte(t,j) == tfirst && j > 1
            skip = j - 2
        end
    end

    i = min(k - n + 1, w + 1)
    while i > 0
        if _nthbyte(s,i) == tfirst
            # check candidate
            j = 1
            while j < n
                if _nthbyte(s,i+j) != _nthbyte(t,j+1)
                    break
                end
                j += 1
            end

            # match found, restore in case `s` is an OffsetArray
            if j == n
                return i + sentinel
            end

            # no match, try to rule out the next character
            if i > 1 && bloom_mask & _search_bloom_mask(_nthbyte(s,i-1)) == 0
                i -= n
            else
                i -= skip
            end
        elseif i > 1
            if bloom_mask & _search_bloom_mask(_nthbyte(s,i-1)) == 0
                i -= n
            end
        end
        i -= 1
    end

    sentinel
end

function _rsearch(s::Union{AbstractString,AbstractVector{<:Union{Int8,UInt8}}},
                  t::Union{AbstractString,AbstractChar,AbstractVector{<:Union{Int8,UInt8}}},
                  i::Integer)
    idx = _rsearchindex(s,t,i)
    if isempty(t)
        idx:idx-1
    elseif idx > firstindex(s) - 1
        idx:(idx + lastindex(t) - 1)
    else
        nothing
    end
end

"""
    findprev(pattern::AbstractString, string::AbstractString, start::Integer)

Find the previous occurrence of `pattern` in `string` starting at position `start`.

The return value is a range of indices where the matching sequence is found, such that
`s[findprev(x, s, i)] == x`:

`findprev("substring", string, i)` == `start:stop` such that
`string[start:stop] == "substring"` and `stop <= i`, or `nothing` if unmatched.

# Examples
```jldoctest
julia> findprev("z", "Hello to the world", 18) === nothing
true

julia> findprev("o", "Hello to the world", 18)
15:15

julia> findprev("Julia", "JuliaLang", 6)
1:5
```
"""
findprev(t::AbstractString, s::AbstractString, i::Integer) = _rsearch(s, t, Int(i))

"""
    findprev(ch::AbstractChar, string::AbstractString, start::Integer)

Find the previous occurrence of character `ch` in `string` starting at position `start`.

!!! compat "Julia 1.3"
    This method requires at least Julia 1.3.

# Examples
```jldoctest
julia> findprev('z', "Hello to the world", 18) === nothing
true

julia> findprev('o', "Hello to the world", 18)
15
```
"""
findprev(ch::AbstractChar, string::AbstractString, start::Integer) =
    findprev(==(ch), string, start)

"""
    findprev(pattern::AbstractVector{<:Union{Int8,UInt8}},
             A::AbstractVector{<:Union{Int8,UInt8}},
             start::Integer)

Find the previous occurrence of the sequence `pattern` in vector `A` starting at position `start`.

!!! compat "Julia 1.6"
    This method requires at least Julia 1.6.

# Examples
```jldoctest
julia> findprev([0x52, 0x62], [0x40, 0x52, 0x62, 0x52, 0x62], 3)
2:3
```
"""
findprev(pattern::AbstractVector{<:Union{Int8,UInt8}},
         A::AbstractVector{<:Union{Int8,UInt8}},
         start::Integer) =
    _rsearch(A, pattern, start)
"""
    occursin(needle::Union{AbstractString,AbstractPattern,AbstractChar}, haystack::AbstractString)

Determine whether the first argument is a substring of the second. If `needle`
is a regular expression, checks whether `haystack` contains a match.

# Examples
```jldoctest
julia> occursin("Julia", "JuliaLang is pretty cool!")
true

julia> occursin('a', "JuliaLang is pretty cool!")
true

julia> occursin(r"a.a", "aba")
true

julia> occursin(r"a.a", "abba")
false
```

See also [`contains`](@ref).
"""
occursin(needle::Union{AbstractString,AbstractChar}, haystack::AbstractString) =
    _searchindex(haystack, needle, firstindex(haystack)) != 0

"""
    occursin(haystack)

Create a function that checks whether its argument occurs in `haystack`, i.e.
a function equivalent to `needle -> occursin(needle, haystack)`.

The returned function is of type `Base.Fix2{typeof(occursin)}`.

!!! compat "Julia 1.6"
    This method requires Julia 1.6 or later.

# Examples
```jldoctest
julia> search_f = occursin("JuliaLang is a programming language");

julia> search_f("JuliaLang")
true

julia> search_f("Python")
false
```
"""
occursin(haystack) = Base.Fix2(occursin, haystack)

in(::AbstractString, ::AbstractString) = error("use occursin(needle, haystack) for string containment")

in(a::UInt8, b::DenseUInt8) = !isnothing(findfirst(==(a), b))
in(a::Int8, b::DenseInt8) = !isnothing(findfirst(==(a), b))
