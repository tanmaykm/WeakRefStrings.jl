__precompile__(true)
module WeakRefStrings

export WeakRefString, WeakRefStringArray, StringArray, StringVector

using Missings, Compat

########################################################################
# WeakRefString
########################################################################

"""
A custom "weakref" string type that only points to external string data.
Allows for the creation of a "string" instance without copying data,
which allows for more efficient string parsing/movement in certain data processing tasks.

**Please note that no original reference is kept to the parent string/memory, so `WeakRefString` becomes unsafe
once the parent object goes out of scope (i.e. loses a reference to it)**

Internally, a `WeakRefString{T}` holds:

  * `ptr::Ptr{T}`: a pointer to the string data (code unit size is parameterized on `T`)
  * `len::Int`: the number of code units in the string data

See also [`WeakRefStringArray`](@ref)
"""
struct WeakRefString{T} <: AbstractString
    ptr::Ptr{T}
    len::Int # of code units
end

WeakRefString(ptr::Ptr{T}, len) where {T} = WeakRefString(ptr, Int(len))
WeakRefString(t::Tuple{Ptr{T}, Int}) where {T} = WeakRefString(t...)
WeakRefString(a::Vector{T}) where T <: Union{UInt8,UInt16,UInt32} = WeakRefString(pointer(a), length(a))

const NULLSTRING = WeakRefString(Ptr{UInt8}(0), 0)
const NULLSTRING16 = WeakRefString(Ptr{UInt16}(0), 0)
const NULLSTRING32 = WeakRefString(Ptr{UInt32}(0), 0)
Base.zero(::Type{WeakRefString{T}}) where {T} = WeakRefString(Ptr{T}(0), 0)

import Base: ==
function ==(x::WeakRefString{T}, y::WeakRefString{T}) where {T}
    x.len == y.len && (x.ptr == y.ptr || ccall(:memcmp, Cint, (Ptr{T}, Ptr{T}, Csize_t),
                                           x.ptr, y.ptr, x.len) == 0)
end
function ==(x::String, y::WeakRefString{T}) where {T}
    sizeof(x) == y.len && ccall(:memcmp, Cint, (Ptr{T}, Ptr{T}, Csize_t),
                                 pointer(x), y.ptr, y.len) == 0
end
==(y::WeakRefString, x::String) = x == y

function Base.hash(s::WeakRefString{T}, h::UInt) where {T}
    h += Base.memhash_seed
    ccall(Base.memhash, UInt, (Ptr{T}, Csize_t, UInt32), s.ptr, s.len, h % UInt32) + h
end

Base.show(io::IO, ::Type{WeakRefString{T}}) where {T} = print(io, "WeakRefString{$T}")
function Base.show(io::IO, x::WeakRefString{T}) where {T}
    print(io, '"')
    print(io, string(x))
    print(io, '"')
    return
end
Base.print(io::IO, s::WeakRefString) = print(io, string(s))
if isdefined(Base, :textwidth)
    Base.textwidth(s::WeakRefString) = textwidth(string(s))
else
    Base.strwidth(s::WeakRefString) = strwidth(string(s))
end

chompnull(x::WeakRefString{T}) where {T} = unsafe_load(x.ptr, x.len) == T(0) ? x.len - 1 : x.len

Base.string(x::WeakRefString) = x == NULLSTRING ? "" : unsafe_string(x.ptr, x.len)
Base.string(x::WeakRefString{UInt16}) = x == NULLSTRING16 ? "" : String(transcode(UInt8, unsafe_wrap(Array, x.ptr, chompnull(x))))
Base.string(x::WeakRefString{UInt32}) = x == NULLSTRING32 ? "" : String(transcode(UInt8, unsafe_wrap(Array, x.ptr, chompnull(x))))

Base.convert(::Type{WeakRefString{UInt8}}, x::String) = WeakRefString(pointer(x), sizeof(x))
Base.convert(::Type{String}, x::WeakRefString) = convert(String, string(x))
Base.String(x::WeakRefString) = string(x)
Base.Symbol(x::WeakRefString{UInt8}) = ccall(:jl_symbol_n, Ref{Symbol}, (Ptr{UInt8}, Int), x.ptr, x.len)

Base.pointer(s::WeakRefString) = s.ptr
Base.pointer(s::WeakRefString, i::Integer) = s.ptr + i - 1

# Iteration. Largely indentical to Julia 0.6's String
function Base.start(s::WeakRefString)
    if s.ptr == C_NULL
        throw(ArgumentError("pointer has been zeroed. The zeroing most likely happened because the string was moved from a process to another."))
    end
    return 1
end

@static if VERSION < v"0.7.0-DEV"

Base.sizeof(s::WeakRefString) = s.len

function Base.endof(s::WeakRefString)
    p = pointer(s)
    i = sizeof(s)
    while i > 0 && Base.is_valid_continuation(unsafe_load(p, i))
        i -= 1
    end
    i
end

@inline function Base.next(s::WeakRefString{UInt8}, i::Int)
    # function is split into this critical fast-path
    # for pure ascii data, such as parsing numbers,
    # and a longer function that can handle any utf8 data
    @boundscheck if (i < 1) | (i > s.len)
        throw(BoundsError(s, i))
    end
    p = pointer(s)
    b = unsafe_load(p, i)
    if b < 0x80
        return Char(b), i + 1
    end
    return Base.slow_utf8_next(p, b, i, sizeof(s))
end

else # 0.7

Base.ncodeunits(s::WeakRefString{T}) where {T} = s.len
Base.codeunit(s::WeakRefString{T}) where {T} = T

@inline function Base.codeunit(s::WeakRefString, i::Integer)
    @boundscheck checkbounds(s, i)
    GC.@preserve s unsafe_load(pointer(s, i))
end

Base.isvalid(s::WeakRefString, i::Int) = checkbounds(Bool, s, i) && thisind(s, i) == i

Base.@propagate_inbounds function Base.next(s::WeakRefString, i::Int)
    b = Base.codeunit(s, i)
    u = UInt32(b) << 24
    Base.between(b, 0x80, 0xf7) || return reinterpret(Char, u), i+1
    return Base.next_continued(s, i, u)
end

function next_continued(s::String, i::Int, u::UInt32)
    u < 0xc0000000 && (i += 1; @goto ret)
    n = ncodeunits(s)
    # first continuation byte
    (i += 1) > n && @goto ret
    @inbounds b = codeunit(s, i)
    b & 0xc0 == 0x80 || @goto ret
    u |= UInt32(b) << 16
    # second continuation byte
    ((i += 1) > n) | (u < 0xe0000000) && @goto ret
    @inbounds b = codeunit(s, i)
    b & 0xc0 == 0x80 || @goto ret
    u |= UInt32(b) << 8
    # third continuation byte
    ((i += 1) > n) | (u < 0xf0000000) && @goto ret
    @inbounds b = codeunit(s, i)
    b & 0xc0 == 0x80 || @goto ret
    u |= UInt32(b); i += 1
@label ret
    return reinterpret(Char, u), i
end

end
########################################################################
# WeakRefStringArray
########################################################################

init(::Type{T}, rows) where {T} = fill(zero(T), rows)
init(::Type{Union{Missing, T}}, rows) where {T} = Vector{Union{Missing, T}}(undef, rows)

"""
A [`WeakRefString`](@ref) container.
Holds the "strong" references to the data pointed by its strings, ensuring that
the referenced memory blocks stay valid during `WeakRefStringArray` lifetime.

Upon indexing an elemnt in a `WeakRefStringArray`, the underlying `WeakRefString` is converted to a proper
Julia `String` type by copying the memory; this ensures safe string processing in the general case. If additional
optimizations are desired, the direct `WeakRefString` elements can be accessed by indexing `A.elements`, where
`A` is a `WeakRefStringArray`.
"""
struct WeakRefStringArray{T<:WeakRefString, N, U} <: AbstractArray{Union{String, U}, N}
    data::Vector{Any}
    elements::Array{Union{T, U}, N}

    WeakRefStringArray(data::Vector{Any}, A::Array{Union{T, Missing}, N}) where {T <: WeakRefString, N} =
        new{T, N, Missing}(data, A)
    WeakRefStringArray(data::Vector{Any}, A::Array{T, N}) where {T <: WeakRefString, N} =
        new{T, N, Union{}}(data, A)
end

WeakRefStringArray(data, ::Type{T}, rows::Integer) where {T} = WeakRefStringArray(Any[data], init(T, rows))
WeakRefStringArray(data, A::Array{T}) where {T <: Union{WeakRefString, Missing}} = WeakRefStringArray(Any[data], A)

wk(A, B::AbstractArray) = WeakRefStringArray(A.data, B)
wk(A, w::WeakRefString) = string(w)
wk(A, ::Missing) = missing

Base.size(A::WeakRefStringArray) = size(A.elements)
Base.getindex(A::WeakRefStringArray, I...) = wk(A, getindex(A.elements, I...))
Base.setindex!(A::WeakRefStringArray{T, N}, v::Missing, i::Int) where {T, N} = setindex!(A.elements, v, i)
Base.setindex!(A::WeakRefStringArray{T, N}, v::Missing, I::Vararg{Int, N}) where {T, N} = setindex!(A.elements, v, I...)
Base.setindex!(A::WeakRefStringArray{T, N}, v::WeakRefString, i::Int) where {T, N} = setindex!(A.elements, v, i)
Base.setindex!(A::WeakRefStringArray{T, N}, v::WeakRefString, I::Vararg{Int, N}) where {T, N} = setindex!(A.elements, v, I...)
Base.setindex!(A::WeakRefStringArray{T, N}, v::String, i::Int) where {T, N} = (push!(A.data, codeunits(v)); setindex!(A.elements, v, i))
Base.setindex!(A::WeakRefStringArray{T, N}, v::String, I::Vararg{Int, N}) where {T, N} = (push!(A.data, codeunits(v)); setindex!(A.elements, v, I...))
if VERSION < v"0.7.0-DEV.3673" # Work around incorrect ambiguity error (PR #26)
    Base.setindex!(A::WeakRefStringArray{T, 1}, v::Missing, i::Int) where {T} = setindex!(A.elements, v, i)
    Base.setindex!(A::WeakRefStringArray{T, 1}, v::WeakRefString, i::Int) where {T} = setindex!(A.elements, v, i)
    Base.setindex!(A::WeakRefStringArray{T, 1}, v::String, i::Int) where {T} = (push!(A.data, codeunits(v)); setindex!(A.elements, v, i))
end
Base.resize!(A::WeakRefStringArray, i) = resize!(A.elements, i)

Base.push!(a::WeakRefStringArray{T, 1}, v::Missing) where {T} = (push!(a.elements, v); a)
Base.push!(a::WeakRefStringArray{T, 1}, v::WeakRefString) where {T} = (push!(a.elements, v); a)
function Base.push!(A::WeakRefStringArray{T, 1}, v::String) where T
    push!(A.data, codeunits(v))
    push!(A.elements, v)
    return A
end

function Base.append!(a::WeakRefStringArray{T, 1}, b::WeakRefStringArray{T, 1}) where {T}
    append!(a.data, b.data)
    append!(a.elements, b.elements)
    return a
end

function Base.vcat(a::WeakRefStringArray{T, 1}, b::WeakRefStringArray{T, 1}) where T
    WeakRefStringArray(Any[a.data, b.data], vcat(a.elements, b.elements))
end


########################################################################
# StringArray
########################################################################

const STR = Union{Missing, <:AbstractString}

"""
`StringArray{T,N}`

Efficient storage for N dimensional array of strings.

`StringArray` stores underlying string data for all elements of the array
in a single contiguous buffer. It maintains offset and length for each
element.

`T` can be `String`, `WeakRefString`, `Union{Missing, String}` or
`Union{Missing, WeakRefString}`. `getindex` will return this type although
all variants have the same storage format.

You can use `convert(StringArray{U}, ::StringArray{T})` to change the
element type (e.g. to `WeakRefString` for efficiency) without copying
the data.

# Example construction

```
julia> sa = StringArray(["x", "y"]) # from Array{String}
2-element WeakRefStrings.StringArray{String,1}:
 "x"
 "y"

julia> sa = StringArray{WeakRefString}(["x", "y"])
2-element WeakRefStrings.StringArray{WeakRefStrings.WeakRefString,1}:
 "x"
 "y"

julia> sa = StringArray{Union{Missing, String}}(["x", "y"]) # with Missing
2-element WeakRefStrings.StringArray{Union{Missings.Missing, String},1}:
 "x"
 "y"

julia> sa = StringArray{Union{Missing, String}}(2,2) # undef
2×2 WeakRefStrings.StringArray{Union{Missings.Missing, String},2}:
 #undef  #undef
 #undef  #undef
```
"""
struct StringArray{T, N} <: AbstractArray{T, N}
    buffer::Vector{UInt8}
    offsets::Array{UInt64, N}
    lengths::Array{UInt32, N}
end

const StringVector{T} = StringArray{T, 1}

const UNDEF_OFFSET = typemax(UInt64)
const MISSING_OFFSET = typemax(UInt64)-1

Base.size(a::StringArray) = size(a.offsets)
Base.IndexStyle(::Type{<:StringVector}) = IndexLinear()

# no-copy convert between eltypes
"""
`convert(StringArray{U}, A::StringArray{T})`

convert `A` to StringArray of another element type (`U`) without
copying the underlying data.
"""
function Base.convert(::Type{<:StringArray{T}}, x::StringArray{<:STR,N}) where {T, N}
    StringArray{T, ndims(x)}(x.buffer, x.offsets, x.lengths)
end

function (::Type{StringArray{T, N}})(dims::Tuple{Vararg{Integer}}) where {T,N}
    StringArray{T,N}(similar(Vector{UInt8}, 0), fill(UNDEF_OFFSET, dims), fill(zero(UInt32), dims))
end

function (::Type{StringArray{T}})(dims::Tuple{Vararg{Integer}}) where {T}
    StringArray{T,length(dims)}(dims)
end

function (::Type{StringArray})(dims::Tuple{Vararg{Integer}})
    StringArray{String}(dims)
end

(::Type{<:StringArray})(dims::Integer...) = StringArray{String,length(dims)}(dims)

function Base.convert(::Type{<:StringArray{T}}, arr::AbstractArray{<:STR, N}) where {T,N}
    s = StringArray{T, N}(size(arr))
    @inbounds for i in eachindex(arr)
        if _isassigned(arr, i)
            s[i] = arr[i]
        else
            s.offsets[i] = UNDEF_OFFSET
            s.lengths[i] = 0
        end
    end
    s
end
Base.convert(::Type{StringArray}, arr::AbstractArray{T}) where {T<:STR} = StringArray{T}(arr)
Base.convert(::Type{StringArray{T, N} where T}, arr::AbstractArray{S}) where {S<:STR, N} = StringVector{S}(arr)
(::Type{StringVector{T}})() where {T} = StringVector{T}(Vector{UInt8}(0), UInt64[], UInt32[])
(::Type{StringVector})() = StringVector{String}()

(T::Type{<:StringArray})(arr::AbstractArray{<:STR}) = convert(T, arr)

_isassigned(arr, i...) = isassigned(arr, i...)
_isassigned(arr, i::CartesianIndex) = isassigned(arr, i.I...)
@inline Base.@propagate_inbounds function Base.getindex(a::StringArray{T}, i::Integer...) where T
    offset = a.offsets[i...]
    if offset == UNDEF_OFFSET
        throw(UndefRefError())
    end

    if Missing <: T && offset === MISSING_OFFSET
        return missing
    end

    convert(T, WeakRefString(pointer(a.buffer) + offset, a.lengths[i...]))
end

function Base.similar(a::StringArray, T::Type{<:STR}, dims::Tuple{Vararg{Int64, N}}) where N
    StringArray{T, N}(dims)
end

function Base.empty!(a::StringVector)
    empty!(a.buffer)
    empty!(a.offsets)
    empty!(a.lengths)
end

Base.copy(a::StringArray{T, N}) where {T,N} = StringArray{T, N}(copy(a.buffer), copy(a.offsets), copy(a.lengths))

@inline function Base.setindex!(arr::StringArray, val::WeakRefString, idx::Integer...)
    p = pointer(arr.buffer)
    if val.ptr <= p + sizeof(arr.buffer)-1 && val.ptr >= p
        # this WeakRefString points to data entirely within arr's buffer
        # don't add anything to the buffer in this case.
        # this optimization helps `permute!`
        arr.offsets[idx...] = val.ptr - p
        arr.lengths[idx...] = val.len
    else
        _setindex!(arr, val, idx...)
    end
end

@inline function Base.setindex!(arr::StringArray, val::STR, idx::Integer...)
    _setindex!(arr, val, idx...)
end

function _setindex!(arr::StringArray, val::AbstractString, idx...)
    buffer = arr.buffer
    l = length(arr.buffer)
    resize!(buffer, l + sizeof(val))
    unsafe_copy!(pointer(buffer, l+1), pointer(val,1), sizeof(val))
    arr.lengths[idx...] = sizeof(val)
    arr.offsets[idx...] = l
    val
end

function _setindex!(arr::StringArray, val::Missing, idx...)
    arr.lengths[idx...] = 0
    arr.offsets[idx...] = MISSING_OFFSET
end

function Base.resize!(arr::StringVector, len)
    l = length(arr)
    resize!(arr.offsets, len)
    resize!(arr.lengths, len)
    if l < len
        arr.offsets[l+1:len] = UNDEF_OFFSET # undef
        arr.lengths[l+1:len] = 0
    end
    arr
end

function Base.push!(arr::StringVector, val::AbstractString)
    l = length(arr.buffer)
    resize!(arr.buffer, l + sizeof(val))
    unsafe_copy!(pointer(arr.buffer, l + 1), pointer(val,1), sizeof(val))
    push!(arr.offsets, l)
    push!(arr.lengths, sizeof(val))
    arr
end

function Base.push!(arr::StringVector, val::Missing)
    push!(arr.offsets, MISSING_OFFSET)
    push!(arr.lengths, 0)
end

function Base.deleteat!(arr::StringVector, idx::Integer)
    deleteat!(arr.lengths, idx)
    deleteat!(arr.offsets, idx)
    arr
end

end # module
