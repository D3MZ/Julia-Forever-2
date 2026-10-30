module JuliaForever2

export greet

"""Return a greeting for `name`."""
greet(name::AbstractString) = "Hello, $(name)!"

end
