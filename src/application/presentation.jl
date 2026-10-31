usage_snapshot(session::Session) = usage_snapshot(session.conversation)

"""Format a usage snapshot without exposing mutable accounting state to a frontend."""
function usage_label(usage::NamedTuple)::String
    usage.reported || return ""
    output = IOBuffer()
    usage.partial && print(output, '~')
    print(output, '↑', usage.input_tokens, " ↓", usage.output_tokens)
    usage.cost_known && print(output, " \$", round(usage.cost; digits=4))
    return String(take!(output))
end

usage_label(conversation::Conversation) = usage_label(usage_snapshot(conversation))
