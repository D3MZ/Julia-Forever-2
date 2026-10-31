mutable struct ResourceRegistration{T,F}
    value::T
    cleanup::F
    lock::ReentrantLock
    active::Bool
end

ResourceRegistration(value, cleanup) = ResourceRegistration(value, cleanup, ReentrantLock(), true)

function release!(registration::ResourceRegistration)
    active = lock(registration.lock) do
        previous = registration.active
        registration.active = false
        previous
    end
    active && Base.invokelatest(registration.cleanup, registration.value)
    return nothing
end

function detach_resource!(registration::ResourceRegistration)
    lock(registration.lock) do
        registration.active = false
    end
    return registration.value
end

const OPERATION_COUNTER = Threads.Atomic{UInt64}(0)
next_operation_id() = Threads.atomic_add!(OPERATION_COUNTER, UInt64(1)) + UInt64(1)

struct ExecutionTaskScope{R,C,O,S}
    runtime::R
    context::C
    owner_context::O
    owners::S
end

function execution_task_scope(; runtime=get(task_local_storage(), :JuliaForever2_runtime, nothing),
        context=get(task_local_storage(), :JuliaForever2_context, nothing),
        owner_context=get(task_local_storage(), :JuliaForever2_owner_context, nothing),
        owners=get(task_local_storage(), :JuliaForever2_owners, ()))
    return ExecutionTaskScope(runtime, context, owner_context, owners)
end

function in_execution_scope(f, scope::ExecutionTaskScope)
    task_local_storage(:JuliaForever2_runtime, scope.runtime) do
        task_local_storage(:JuliaForever2_context, scope.context) do
            task_local_storage(:JuliaForever2_owner_context, scope.owner_context) do
                task_local_storage(:JuliaForever2_owners, scope.owners) do
                    Base.invokelatest(f)
                end
            end
        end
    end
end

spawn_scoped(f, scope=execution_task_scope()) = Threads.@spawn in_execution_scope(f, scope)

mutable struct ExecutionContext{F}
    stopped::Threads.Atomic{Bool}
    deadline::Float64
    interrupt::Base.Event
    sink::F
    timer::Union{Nothing,Timer}
    lock::ReentrantLock
    listeners::Vector{Base.Event}
    parent::Union{Nothing,ExecutionContext}
    resources::Vector{ResourceRegistration}
    closed::Bool
    claimed::Bool
    operation_id::UInt64
    owners::Tuple
end

monotonic_seconds() = time_ns() / 1.0e9

function ExecutionContext(; timeout::Real=Inf, emit=Returns(nothing), event_sink=emit, parent=nothing)
    deadline = monotonic_seconds() + max(0.0, Float64(timeout))
    isnothing(parent) || (deadline = min(deadline, parent.deadline))
    context = ExecutionContext(Threads.Atomic{Bool}(false), deadline, Base.Event(), event_sink, nothing,
        ReentrantLock(), Base.Event[], parent, ResourceRegistration[], false, false, next_operation_id(), ())
    isnothing(parent) || register_cancellation!(parent, context.interrupt; owned=false)
    if isfinite(deadline)
        context.timer = Timer(remaining_time(context)) do timer
            cancel!(context)
        end
    end
    return context
end

"""Register a resource with the operation owner, which survives failure of its worker."""
function own_resource!(context::ExecutionContext, value; cleanup=close)
    registration = ResourceRegistration(value, cleanup)
    accepted = lock(context.lock) do
        if context.closed
            false
        else
            push!(context.resources, registration)
            true
        end
    end
    accepted || release!(registration)
    return registration
end

track_component_lease!(context::ExecutionContext, lease::ComponentLease) = own_resource!(context, lease; cleanup=release!)
transfer_component_lease!(registration::ResourceRegistration) = detach_resource!(registration)

function cancel!(context::ExecutionContext)
    lock(context.lock) do
        context.stopped[] = true
        notify(context.interrupt)
        foreach(notify, context.listeners)
    end
    return nothing
end

function register_cancellation!(context::ExecutionContext, event::Base.Event; owned=true)
    lock(context.lock) do
        push!(context.listeners, event)
        cancelled(context) && notify(event)
    end
    parent = context.parent
    isnothing(parent) || register_cancellation!(parent, event; owned=false)
    owned && own_resource!(context, event; cleanup=event -> unregister_cancellation!(context, event))
    return event
end

function unregister_cancellation!(context::ExecutionContext, event::Base.Event)
    lock(context.lock) do
        filter!(listener -> listener !== event, context.listeners)
    end
    parent = context.parent
    isnothing(parent) || unregister_cancellation!(parent, event)
    return nothing
end

cancelled(::Nothing) = false
cancelled(context::ExecutionContext) = context.stopped[] || monotonic_seconds() >= context.deadline || cancelled(context.parent)
remaining_time(context::ExecutionContext) = max(0.0, context.deadline - monotonic_seconds())
cancellation_event(context::ExecutionContext) = context.interrupt
operation_id(context::ExecutionContext) = context.operation_id
emit!(context::ExecutionContext, event) = context.sink(event)

function release_context_resources!(context::ExecutionContext)
    resources = lock(context.lock) do
        context.closed = true
        pending = copy(context.resources)
        empty!(context.resources)
        pending
    end
    timer = context.timer
    isnothing(timer) || close(timer)
    parent = context.parent
    isnothing(parent) || unregister_cancellation!(parent, context.interrupt)
    failures = Task[]
    for registration in reverse(resources)
        active = lock(() -> registration.active, registration.lock)
        active || continue
        cleanup = spawn_cleanup(() -> release!(registration); owners=context.owners)
        wait(cleanup; throw=false)
        istaskfailed(cleanup) && push!(failures, cleanup)
    end
    return failures
end

"""Run cleanup with its own resource scope while preserving the owning session lineage."""
function spawn_cleanup(f; owners=get(task_local_storage(), :JuliaForever2_owners, ()))
    context = ExecutionContext()
    context.claimed = true
    context.owners = owners
    scope = execution_task_scope(; runtime=nothing, context, owner_context=context, owners)
    worker = spawn_scoped(f, scope)
    return spawn_scoped(scope) do
        wait(worker; throw=false)
        failures = release_context_resources!(context)
        istaskfailed(worker) && return fetch(worker)
        isempty(failures) || fetch(first(failures))
        fetch(worker)
    end
end

function Base.close(context::ExecutionContext)
    failures = release_context_resources!(context)
    isempty(failures) || fetch(first(failures))
    return nothing
end

current_context() = get(task_local_storage(), :JuliaForever2_context, nothing)
execution_context(::Nothing) = ExecutionContext()
execution_context(context::ExecutionContext) = context
current_execution_context() = execution_context(current_context())
child_context(::Nothing) = ExecutionContext()
child_context(parent::ExecutionContext) = ExecutionContext(; parent, event_sink=parent.sink)
stopped_result() = ExecutionResult(false, "Execution cancelled.")

function claim_context!(context::ExecutionContext, owners)
    available = lock(context.lock) do
        if context.claimed || context.closed
            false
        else
            context.claimed = true
            context.owners = owners
            true
        end
    end
    return available ? context : claim_context!(child_context(context), owners)
end
