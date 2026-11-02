struct CommandHotkeyTable
    markdown::String
end

"""Ephemeral command output belongs to a frontend session, never its model history or JSONL archive."""
struct CommandSessionInfo
    statistics::JuliaForever2.SessionStatistics
    cache_mode::String
    selected_model::Union{Nothing,String}
end

struct InlineCommandDocument
    title::String
    content::Union{String,JuliaForever2.SessionStatistics,CommandSessionInfo,CommandHotkeyTable}
    anchor::Union{Nothing,String}
end
Base.@kwdef mutable struct CommandDocumentState
    owner::Union{Nothing,String} = nothing
    documents::Vector{InlineCommandDocument} = InlineCommandDocument[]
    revision::UInt = UInt(0)
end
