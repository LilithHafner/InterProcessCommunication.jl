#
# semaphores.jl --
#
# Implements semaphores for Julia.
#
#------------------------------------------------------------------------------
#
# This file is part of IPC.jl released under the MIT "expat" license.
# Copyright (C) 2016-2017, Éric Thiébaut (https://github.com/emmt/IPC.jl).
#

"""
# Semaphores

A semaphore is associated with an integer value which is never allowed to fall
below zero.  Two operations can be performed on semaphores: increment the
semaphore value by one with `post(sem)`; and decrement the semaphore value by
one with `wait(sem)`.  If the value of a semaphore is currently zero, then a
`wait(sem)` call will block until the value becomes greater than zero.  The
method `getvalue(sem)` yields the current value of the semaphore.

There are two kinds of semaphores: *named* and *anonymous* semaphores.  Named
semaphores are identified by their name which is a string of the form
`"/somename"`.  Anonymous semaphores are backed by *memory* objects (usually
shared memory) providing the necessary storage.  In Julia IPC package,
semaphores are instances of `Semaphore{T}` where `T` is `String` for named
semaphores and the type of the backing memory object for anonymous semaphores.

To query the value of semaphore `sem`, do:

```julia
sem[]
```

Beware that the value of the semaphore may already have changed by the time the
result is returned.  The minimal and maximal values that can take a semaphore
are given by:

```julia
typemin(Semaphore)
typemax(Semaphore)
```

## Named Semaphores

```julia
Semaphore(name, value; perms=0o600, volatile=true) -> sem
```

creates a new named semaphore identified by the string `name` of the form
`"/somename"` and initial value set to `value`.  An instance of
`Semaphore{String}` is returned.  Keyword `perms` can be used to specify access
permissions.  Keyword `volatile` specify whether the semaphore should be
unlinked when the returned object is garbage collected.

```julia
Semaphore(name) -> sem
```

opens an existing named semaphore and returns an instance of
`Semaphore{String}`.

To unlink (remove) a persistent named semaphore, simply do:

```julia
rm(Semaphore, name)
```

If the semaphore does not exists, the error is ignored.  A `SystemError` is
however thrown for other errors.


## Anonymous Semaphores

Anonymous semaphores are backed by *memory* objects providing the necessary
storage.

```julia
Semaphore(mem, value; offset=0, volatile=true) -> sem
```

initializes an anonymous semaphore backed by memory object `mem` with initial
value set to `value` and returns an instance of `Semaphore{typeof(mem)}`.
Keyword `offset` can be used to specify the address (in bytes) of the semaphore
data relative to `pointer(mem)`.  Keyword `volatile` specify whether the
semaphore should be destroyed when the returned object is garbage collected.

```julia
Semaphore(mem; offset=0) -> sem
```

yields an an instance of `Semaphore{typeof(mem)}` associated with an
initialized anonymous semaphore and backed by memory object `mem` at relative
offset `offset`.

To figure out the number of bytes needed to store a semaphore, simply call:

```julia
sizeof(Semaphore)
```

See also: [`post`](@ref), [`wait`](@ref), [`timedwait`](@ref),
[`trywait`](@ref).

"""
function Semaphore(name::AbstractString, value::Integer;
                   perms::Integer = S_IRUSR | S_IWUSR,
                   volatile::Bool = true)
    val = _check_semaphore_value(value)
    mode = maskmode(perms)
    flags = O_CREAT | O_EXCL
    return open(Semaphore, name, flags, mode, val, volatile)
end

function Semaphore(name::AbstractString)
    flags = zero(Cint)
    mode = zero(_typeof_mode_t)
    value = zero(Cuint)
    return open(Semaphore, name, flags, mode, value, false)
end

function Base.open(::Type{Semaphore}, name::AbstractString, flags::Integer,
                   mode::Unsigned, value::Unsigned, volatile::Bool)
    ptr = _sem_open(name, flags, mode, value)
    systemerror("sem_open", ptr == SEM_FAILED)
    sem = Semaphore{String}(ptr, name)
    if volatile
        finalizer(sem, _close_and_unlink)
    else
        finalizer(sem, _close)
    end
    return sem
end

# Initialize and anonymous semaphore.
function Semaphore(mem::M, value::Integer;
                   offset::Integer = 0,
                   volatile::Bool = true) where {M}
    val = _check_semaphore_value(value)
    ptr = _get_semaphore_address(mem, offset)
    systemerror("sem_init",
                _sem_init(ptr, true, val) != SUCCESS)
    sem = Semaphore{M}(ptr, mem)
    if volatile
        finalizer(sem, _destroy)
    end
    return sem
end

# Connect to an initialized anonymous semaphore.
function Semaphore(mem::M; offset::Integer = 0) where {M}
    ptr = _get_semaphore_address(mem, offset)
    return Semaphore{M}(ptr, mem)
end

# Unlink (remove) a named semaphore.
function Base.rm(::Type{Semaphore}, name::AbstractString)
    if _sem_unlink(name) != SUCCESS
        errno = Libc.errno()
        if errno != Libc.ENOENT
            throw_system_error("sem_unlink", errno)
        end
    end
end

Base.sizeof(::Type{Semaphore}) = _sizeof_sem_t
Base.typemin(::Type{Semaphore}) = zero(Cuint)
Base.typemax(::Type{Semaphore}) = SEM_VALUE_MAX

function _check_semaphore_value(value::Integer)
    typemin(Semaphore) ≤ value ≤ typemax(Semaphore) ||
        throw_argument_error("invalid semaphore value ($value)")
    return convert(Cuint, value)
end

function _get_semaphore_address(mem, off::Integer)::Ptr{Void}
    off ≥ 0 || throw_argument_error("offset must be nonnegative ($off)")
    ptr, siz = get_memory_parameters(mem)
    siz ≥ off + _sizeof_sem_t ||
        throw_argument_error("not enough memory at given offset")
    # FIXME: check alignment?
    return ptr + off
end

# Finalize a named semaphore.
function _close(obj::Semaphore{String})
    _sem_close(obj.ptr)
end

# Finalize a named semaphore.
function _close_and_unlink(obj::Semaphore{String})
    _sem_close(obj.ptr)
    _sem_unlink(obj.lnk)
end

# Finalize an anonymous semaphore.
function _destroy(obj::Semaphore)
    _sem_destroy(obj.ptr)
end

function Base.getindex(sem::Semaphore)
    val = Ref{Cint}()
    systemerror("sem_getvalue", _sem_getvalue(sem.ptr, val) != SUCCESS)
    return val[]
end

Base.convert(::Type{T}, sem::Semaphore) where {T<:Integer} =
    convert(T, sem[])

"""
```julia
post(sem)
```

increments (unlocks) the semaphore `sem`.  If the semaphore's value
consequently becomes greater than zero, then another process or thread blocked
in a [`wait`](@ref) call will be woken up and proceed to lock the semaphore.

See also: [`Semaphore`](@ref), [`wait`](@ref), [`timedwait`](@ref),
[`trywait`](@ref).

"""
post(sem::Semaphore) =
    systemerror("sem_post", _sem_post(sem.ptr) != SUCCESS)

"""
```julia
wait(sem)
```

decrements (locks) the semaphore `sem`.  If the semaphore's value is greater
than zero, then the decrement proceeds, and the function returns, immediately.
If the semaphore currently has the value zero, then the call blocks until
either it becomes possible to perform the decrement (i.e., the semaphore value
rises above zero), or a signal handler interrupts the call (in which case an
instance of `InterruptException` is thrown).  A `SystemError` may be thrown if
an unexpected error occurs.

See also: [`Semaphore`](@ref), [`post`](@ref), [`timedwait`](@ref),
[`trywait`](@ref).

"""
function Base.wait(sem::Semaphore)
    if _sem_wait(sem.ptr) != SUCCESS
        code = Libc.errno()
        if code == Libc.EINTR
            throw(InterruptException())
        else
            throw_system_error("sem_wait", code)
        end
    end
    nothing
end

"""
```julia
timedwait(sem, secs)
```

decrements (locks) the semaphore `sem`.  If the semaphore's value is greater
than zero, then the decrement proceeds, and the function returns, immediately.
If the semaphore currently has the value zero, then the call blocks until
either it becomes possible to perform the decrement (i.e., the semaphore value
rises above zero), or the limit of `secs` seconds expires (in which case an
instance of `IPC.TimeoutError` is thrown), or a signal handler interrupts the
call (in which case an instance of `InterruptException` is thrown).

See also: [`Semaphore`](@ref), [`post`](@ref), [`wait`](@ref),  [`trywait`](@ref).

"""
Base.timedwait(sem::Semaphore, secs::Real) =
    timedwait(sem::Semaphore, convert(Float64, secs))

function Base.timedwait(sem::Semaphore, secs::Float64)
    tsref = Ref{TimeSpec}(time() + secs)
    if _sem_timedwait(sem.ptr, tsref) != SUCCESS
        code = Libc.errno()
        if code == Libc.EINTR
            throw(InterruptException())
        elseif code == Libc.ETIMEDOUT
            throw(TimeoutError())
        else
            throw_system_error("sem_timedwait", code)
        end
    end
    nothing
end

"""
```julia
trywait(sem) -> boolean
```

attempts to immediately decrements (locks) the semaphore `sem` returning `true`
if successful.  If the decrement cannot be immediately performed, then the call
returns `false`.  If an interruption is received or if an unexpected error is
returned, an exception is thrown (`InterruptException` or `SystemError`
repectively).

See also: [`Semaphore`](@ref), [`post`](@ref), [`wait`](@ref),  [`timedwait`](@ref).

"""
function trywait(sem::Semaphore)
    if _sem_trywait(sem.ptr) == SUCCESS
        return true
    end
    code = Libc.errno()
    if code == Libc.EAGAIN
        return false
    end
    if code == Libc.EINTR
        throw(InterruptException())
    else
        throw_system_error("sem_trywait", code)
    end
end