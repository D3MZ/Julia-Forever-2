# Native sRGB/Oklab/OKHSL mathematics; numerical interoperability vectors use
# earendil-works/pi at 2c8d1feb147f6b3d97e855da803bfe7b19f3c403 (MIT).
# Oklab/OKHSL equations Copyright (c) 2021 Björn Ottosson, MIT:
# Permission is hereby granted, free of charge, to any person obtaining a copy of
# this software and associated documentation files (the "Software"), to deal in
# the Software without restriction, including without limitation the rights to
# use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
# the Software, and to permit persons to whom the Software is furnished to do so,
# subject to the following conditions: The above copyright notice and this
# permission notice shall be included in all copies or substantial portions of
# the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO
# EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES
# OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
# ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
# DEALINGS IN THE SOFTWARE.

const THEME_RGB_LMS = ((0.4122214694707629,0.5363325372617349,0.0514459932675022),
    (0.2119034958178251,0.6806995506452344,0.1073969535369405),(0.0883024591900564,0.2817188391361215,0.6299787016738222))
const THEME_LMS_LAB = ((0.210454268309314,0.793617774702305,-0.0040720430116193),
    (1.9779985324311684,-2.42859224204858,0.450593709617411),(0.0259040424655478,0.7827717124575296,-0.8086757549230774))
const THEME_LAB_LMS = ((1.0,0.3963377773761749,0.2158037573099136),
    (1.0,-0.1055613458156586,-0.0638541728258133),(1.0,-0.0894841775298119,-1.2914855480194092))
const THEME_LMS_RGB = ((4.0767416360759583,-3.3077115392580629,0.2309699031821043),
    (-1.2684379732850315,2.6097573492876882,-0.341319376002657),(-0.0041960761386756,-0.7034186179359362,1.7076146940746117))
const THEME_SATURATION_FIT = ((1.19086277,1.76576728,0.59662641,0.75515197,0.56771245),
    (0.73956515,-0.45954404,0.08285427,0.12541073,-0.14503204),(1.35733652,-0.00915799,-1.1513021,-0.50559606,0.00692167))
const THEME_TOE_K = 1.206 / 1.03

theme_dot(a,b) = a[1]*b[1]+a[2]*b[2]+a[3]*b[3]
theme_matvec(matrix,value) = map(row -> theme_dot(row,value),matrix)
theme_linear(value::Real) = value <= 0.04045 ? value/12.92 : ((value+0.055)/1.055)^2.4
theme_encoded(value::Real) = value > 0.0031308 ? 1.055*value^(1/2.4)-0.055 : 12.92*value
theme_rgb(color::Tachikoma.ColorRGB) = (Int(color.r),Int(color.g),Int(color.b))
theme_rgb(color::Tachikoma.Color256) = theme_rgb(Tachikoma.to_rgb(color))
theme_lab(rgb) = theme_matvec(THEME_LMS_LAB, map(cbrt,theme_matvec(THEME_RGB_LMS,map(value -> theme_linear(value/255),rgb))))
theme_lab_linear(lab) = theme_matvec(THEME_LMS_RGB,map(value -> value^3,theme_matvec(THEME_LAB_LMS,lab)))
theme_quantized(linear) = map(value -> floor(Int,clamp(theme_encoded(value),0,1)*255+0.5),linear)
theme_toe(value) = 0.5*(THEME_TOE_K*value-0.206+sqrt((THEME_TOE_K*value-0.206)^2+4*0.03*THEME_TOE_K*value))
theme_toe_inverse(value) = (value^2+0.206*value)/(THEME_TOE_K*(value+0.03))
theme_slopes(a,b) = map(row -> row[2]*a+row[3]*b,THEME_LAB_LMS)

"""Find the red/green/blue gamut cusp along a normalized Oklab chroma direction."""
function theme_cusp(a,b)
    channel = -1.8817031*a-0.80936501*b > 1 ? 1 : (1.8144408*a-1.19445267*b > 1 ? 2 : 3)
    coefficients = THEME_SATURATION_FIT[channel]
    saturation = coefficients[1]+coefficients[2]*a+coefficients[3]*b+coefficients[4]*a*a+coefficients[5]*a*b
    slopes = theme_slopes(a,b)
    bases = map(k -> 1+saturation*k,slopes)
    weights = THEME_LMS_RGB[channel]
    f = theme_dot(weights,map(value -> value^3,bases))
    f1 = theme_dot(weights,map((k,v) -> 3*k*v^2,slopes,bases))
    f2 = theme_dot(weights,map((k,v) -> 6*k^2*v,slopes,bases))
    saturation -= f*f1/(f1*f1-0.5*f*f2)
    lightness = cbrt(1/maximum(theme_lab_linear((1,saturation*a,saturation*b))))
    (lightness,lightness*saturation)
end

"""Intersect a fixed-lightness chroma ray with the sRGB gamut boundary."""
function theme_max_chroma(a,b,lightness,peak)
    peak_l,peak_c = peak
    if lightness <= peak_l
        peak_c*lightness/peak_l
    else
        distance = peak_c*(lightness-1)/(peak_l-1)
        slopes = theme_slopes(a,b)
        lms = map(k -> lightness+distance*k,slopes)
        cubes = map(v -> v^3,lms)
        first = map((k,v) -> 3*k*v^2,slopes,lms)
        second = map((k,v) -> 6*k^2*v,slopes,lms)
        corrections = map(THEME_LMS_RGB) do weights
            f = theme_dot(weights,cubes)-1
            f1,f2 = theme_dot(weights,first),theme_dot(weights,second)
            factor = f1/(f1*f1-0.5*f*f2)
            factor >= 0 ? -f*factor : floatmax(Float64)
        end
        distance+minimum(corrections)
    end
end

"""Compute perceptually spaced low, middle and maximum OKHSL chroma anchors."""
function theme_chroma_stops(lightness,a,b)
    peak = theme_cusp(a,b)
    high = theme_max_chroma(a,b,lightness,peak)
    scale = high/min(lightness*(peak[2]/peak[1]),(1-lightness)*(peak[2]/(1-peak[1])))
    mids = 0.11516993+1/(7.4477897+4.1590124*b+a*(-2.19557347+1.75198401*b+a*(-2.13704948-10.02301043*b+a*(-4.24894561+5.38770819*b+4.69891013*a))))
    midt = 0.11239642+1/(1.6132032-0.68124379*b+a*(0.40370612+0.90148123*b+a*(-0.27087943+0.6122399*b+a*(0.00299215-0.45399568*b-0.14661872*a))))
    middle = 0.9*scale*sqrt(sqrt(1/(1/(lightness*mids)^4+1/((1-lightness)*midt)^4)))
    low = sqrt(1/(1/(lightness*0.4)^2+1/((1-lightness)*0.8)^2))
    (low,middle,high)
end

"""Convert OKHSL channels to integer sRGB without a JavaScript runtime."""
function theme_okhsl_rgb(hue,saturation,lightness)
    value = theme_toe_inverse(lightness)
    lab = (value,0.0,0.0)
    if 0 < value < 1 && saturation > 0
        angle = 2*pi*mod(hue,360)/360
        a,b = cos(angle),sin(angle)
        low,middle,high = theme_chroma_stops(value,a,b)
        chroma = if saturation < 0.8
            position,scale = 1.25*saturation,0.8*low
            position*scale/(1-(1-scale/middle)*position)
        else
            position,scale = 5*(saturation-0.8),0.2*middle^2*1.25^2/low
            middle+position*scale/(1-(1-scale/(high-middle))*position)
        end
        lab = (value,chroma*a,chroma*b)
    end
    theme_quantized(theme_lab_linear(lab))
end

"""Convert integer sRGB into OKHSL channels for terminal-palette adaptation."""
function theme_rgb_okhsl(rgb)
    lightness,a,b = theme_lab(rgb)
    chroma = hypot(a,b)
    output_lightness = theme_toe(lightness)
    if chroma < 1e-9 || output_lightness <= 0 || output_lightness >= 1
        (h=0.0,s=0.0,l=output_lightness)
    else
        hue = mod(atan(b,a)*180/pi+360,360)
        low,middle,high = theme_chroma_stops(lightness,a/chroma,b/chroma)
        saturation = if chroma < middle
            scale = 0.8*low
            0.8*(chroma/(scale+(1-scale/middle)*chroma))
        else
            scale,offset = 0.2*middle^2*1.25^2/low,chroma-middle
            0.8+0.2*(offset/(scale+(1-scale/(high-middle))*offset))
        end
        (h=hue,s=clamp(saturation,0,1),l=output_lightness)
    end
end

"""Map OKLCH into sRGB by reducing chroma at a fixed hue and lightness."""
function theme_oklch_rgb(lightness,chroma,hue)
    angle = mod(hue,360)*pi/180
    at(amount) = theme_lab_linear((lightness,amount*cos(angle),amount*sin(angle)))
    inside(values) = all(value -> -1e-7 <= value <= 1+1e-7,values)
    linear = at(chroma)
    if !inside(linear)
        linear = at(0)
        low,high = 0.0,Float64(chroma)
        for _ in 1:20
            middle = (low+high)/2
            candidate = at(middle)
            if inside(candidate)
                low,linear = middle,candidate
            else
                high = middle
            end
        end
    end
    theme_quantized(linear)
end

const THEME_COLOR_NUMBER = raw"[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?"
const THEME_OKHSL_PATTERN = Regex("^okhsl\\(\\s*("*THEME_COLOR_NUMBER*")(?:deg)?\\s+("*THEME_COLOR_NUMBER*")(%?)\\s+("*THEME_COLOR_NUMBER*")(%?)\\s*\\)\$","i")
const THEME_OKLCH_PATTERN = Regex("^oklch\\(\\s*("*THEME_COLOR_NUMBER*")(%?)\\s+("*THEME_COLOR_NUMBER*")\\s+("*THEME_COLOR_NUMBER*")(?:deg)?\\s*\\)\$","i")

"""Parse a supported theme color, reporting invalid values as nothing rather than fallback success."""
theme_color(value) = nothing
theme_color(value::Bool) = nothing
theme_color(value::Real) = isfinite(value) && isinteger(value) && 0<=value<=255 ? Tachikoma.Color256(Int(value)) : nothing
theme_color(value::Integer) = 0 <= value <= 255 ? Tachikoma.Color256(Int(value)) : nothing
function theme_color(value::AbstractString)
    color = nothing
    hex = match(r"^#([\da-f]{3}|[\da-f]{6})$"i,value)
    hsl,lch = match(THEME_OKHSL_PATTERN,value),match(THEME_OKLCH_PATTERN,value)
    if isempty(value)
        color = Tachikoma.NoColor()
    elseif !isnothing(hex)
        digits = String(something(hex.captures[1],""))
        digits = length(digits)==3 ? join(repeat(string(c),2) for c in digits) : digits
        color = Tachikoma.ColorRGB((parse(UInt8,digits[i:i+1];base=16) for i in (1,3,5))...)
    elseif !isnothing(hsl)
        hue = parse(Float64,something(hsl.captures[1],"NaN"))
        saturation = parse(Float64,something(hsl.captures[2],"NaN"))/(hsl.captures[3]=="%" ? 100 : 1)
        lightness = parse(Float64,something(hsl.captures[4],"NaN"))/(hsl.captures[5]=="%" ? 100 : 1)
        if all(isfinite,(hue,saturation,lightness)) && 0 <= saturation <= 1 && 0 <= lightness <= 1
            color = Tachikoma.ColorRGB(theme_okhsl_rgb(hue,saturation,lightness)...)
        end
    elseif !isnothing(lch)
        lightness = parse(Float64,something(lch.captures[1],"NaN"))/(lch.captures[2]=="%" ? 100 : 1)
        chroma,hue = parse(Float64,something(lch.captures[3],"NaN")),parse(Float64,something(lch.captures[4],"NaN"))
        if all(isfinite,(lightness,chroma,hue)) && 0 <= lightness <= 1 && chroma >= 0
            color = Tachikoma.ColorRGB(theme_oklch_rgb(lightness,chroma,hue)...)
        end
    end
    color
end

"""Choose the original cube/grayscale ANSI-256 approximation for a concrete RGB token."""
function theme_indexed(color::Tachikoma.ColorRGB)
    rgb = theme_rgb(color)
    cube = (0,95,135,175,215,255)
    gray = ntuple(index -> 8+10*(index-1),24)
    indexes = map(value -> argmin(abs.(cube .- value)),rgb)
    cube_rgb = map(index -> cube[index],indexes)
    index = 16+36*(indexes[1]-1)+6*(indexes[2]-1)+indexes[3]-1
    gray_value = floor(Int,theme_dot((0.299,0.587,0.114),rgb)+0.5)
    gray_index = argmin(abs.(gray .- gray_value))
    distance(a,b) = theme_dot((0.299,0.587,0.114),map((x,y)->(x-y)^2,a,b))
    if maximum(rgb)-minimum(rgb)<10 && distance(rgb,(gray[gray_index],gray[gray_index],gray[gray_index]))<distance(rgb,cube_rgb)
        index = 232+gray_index-1
    end
    Tachikoma.Color256(index)
end
theme_indexed(color::Tachikoma.AbstractColor) = color
