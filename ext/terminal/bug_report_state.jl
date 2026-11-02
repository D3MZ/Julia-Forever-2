"""One explicitly invoked bug report owns its input and consent independently of the chat editor."""
Base.@kwdef mutable struct BugReportControl
    owner::String
    editor::ChatEditorState
    stage::Symbol = :description
    selected::Int = 1
    description::String = ""
    transcript::Bool = false
    summary::Bool = false
    model_name::String = "the current model"
    provider::Union{Nothing,String} = nothing
    model::Union{Nothing,String} = nothing
    result_path::Union{Nothing,String} = nothing
end
