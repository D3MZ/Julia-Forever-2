"""Own a transient catalog lookup without granting a delayed result authority over a newer view."""
Base.@kwdef struct ModelCommandLookup
    query::String
    generation::UInt
    page::Symbol
    request::UInt
end
