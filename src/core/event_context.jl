struct ScopedEventSink{S,F}
    scope::S
    downstream::F
end

function (sink::ScopedEventSink)(event::HarnessEvent)
    dispatch_event!(sink.scope, event.kind, event.data)
    return Base.invokelatest(sink.downstream, event)
end

execution_event_sink(sink, scope::ExtensionScope) = ScopedEventSink(scope, sink)

"""Provide a native event scope that plugins can depend on and use as an execution event sink."""
function event_scope_plugin(name=:events; service_name=:events)
    return PluginSpec(name, context -> provide!(context, service_name, ExtensionScope(); cleanup=close);
        provides=[service_name])
end
