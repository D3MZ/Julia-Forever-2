usage_snapshot(session::Session) = usage_snapshot(session.conversation)

"""Format a usage snapshot without exposing mutable accounting state to a frontend."""
usage_label(usage::NamedTuple)::String = usage.reported ? render(usage) : ""

function render(usage::NamedTuple)
    output = IOBuffer()
    if usage.partial
        print(output, '~')
    end
    print(output, '↑', usage.input_tokens, " ↓", usage.output_tokens)
    if usage.cost_known
        print(output, " \$", round(usage.cost; digits=4))
    end
    String(take!(output))
end
usage_label(conversation::Conversation) = usage_label(usage_snapshot(conversation))
