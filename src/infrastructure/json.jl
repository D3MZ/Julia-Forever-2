module JSONCodec

using JSON

parse_json(text::AbstractString) = JSON.isvalidjson(text) ? JSON.parse(text) : nothing

end

using .JSONCodec: parse_json
