
Base.isempty(::EmptyCell) = true
Base.isempty(::AbstractCell) = false
iserror(c::Cell) = c.datatype == "e"
iserror(::AbstractCell) = false
row_number(c::EmptyCell) = row_number(c.ref)
column_number(c::EmptyCell) = column_number(c.ref)
row_number(c::Cell) = row_number(c.ref)
column_number(c::Cell) = column_number(c.ref)

function Cell(c::EzXML.Node)
    # c (Cell) element is defined at section 18.3.1.4
    # t (Cell Data Type) is an enumeration representing the cell's data type. The possible values for this attribute are defined by the ST_CellType simple type (§18.18.11).
    # s (Style Index) is the index of this cell's style. Style records are stored in the Styles Part.

    @assert EzXML.nodename(c) == "c" "`Cell` Expects a `c` (cell) XML node."

    ref = CellRef(c["r"])

    # type
    if haskey(c, "t")
        t = c["t"]
    else
        t = ""
    end

    # style
    if haskey(c, "s")
        s = c["s"]
    else
        s = ""
    end

    # iterate v and f elements
    local v::String = ""
    local f::String = ""
    local found_v::Bool = false
    local found_f::Bool = false
    for c_child_element in EzXML.eachelement(c)
        if EzXML.nodename(c_child_element) == "v"

            # we should have only one v element
            if found_v
                error("Unsupported: cell $(ref) has more than 1 `v` elements.")
            else
                found_v = true
            end

            v = EzXML.nodecontent(c_child_element)
        elseif EzXML.nodename(c_child_element) == "f"

            # we should have only one f element
            if found_f
                error("Unsupported: cell $(ref) has more than 1 `f` elements.")
            else
                found_f = true
            end

            f = EzXML.nodecontent(c_child_element)
        end
    end

    return Cell(ref, t, s, v, f)
end

celldata(ws::Worksheet, empty::EmptyCell) = Missings.missing
getdata(ws::Worksheet, cell::AbstractCell) = celldata(ws, cell)

"""
    celldata(ws::Worksheet, cell::Cell) :: Union{String, Missings.missing, Float64, Int, Bool, Dates.Date, Dates.Time, Dates.DateTime}

Returns a Julia representation of a given cell value.
The result data type is chosen based on the value of the cell as well as its style.

For example, date is stored as integers inside the spreadsheet, and the style is the
information that is taken into account to chose `Date` as the result type.

For numbers, if the style implies that the number is visualized with decimals,
the method will return a float, even if the underlying number is stored
as an integer inside the spreadsheet XML.

If `cell` has empty value or empty `String`, this function will return `Missings.missing`.
"""
function celldata(ws::Worksheet, cell::Cell) :: Union{String, Missings.Missing, Float64, Int, Bool, Dates.Date, Dates.Time, Dates.DateTime}

    if iserror(cell)
        return Missings.missing
    end

    if cell.datatype == "inlineStr"
        error("datatype inlineStr not supported...")
    end

    if cell.datatype == "s"
        # use sst
        str = sst_unformatted_string(ws, cell.value)

        if isempty(str)
            return Missings.missing
        else
            return str
        end

    elseif (isempty(cell.datatype) || cell.datatype == "n")

        if isempty(cell.value)
            return Missings.missing
        end

        if !isempty(cell.style) && styles_is_datetime(ws, cell.style)
            # datetime
            return _celldata_datetime(cell.value, isdate1904(ws))

        elseif !isempty(cell.style) && styles_is_float(ws, cell.style)

            # float
            return parse(Float64, cell.value)

        else
            # fallback to unformatted number
            if contains(cell.value, ".")
                v_num = parse(Float64, cell.value)
            else
                v_num = parse(Int64, cell.value)
            end

            return v_num
        end
    elseif cell.datatype == "b"
        if cell.value == "0"
            return false
        elseif cell.value == "1"
            return true
        else
            error("Unknown boolean value: $(cell.value).")
        end
    elseif cell.datatype == "str"
        # plain string
        if isempty(cell.value)
            return Missings.missing
        else
            return cell.value
        end
    end

    error("Couldn't parse celldata for $cell.")
end


function _celldata_datetime(v::AbstractString, _is_date_1904::Bool) :: Union{Dates.DateTime, Dates.Date, Dates.Time}

    # does not allow empty string
    @assert !isempty(v) "Cannot convert an empty string into a datetime value."

    if contains(v, ".")
        time_value = parse(Float64, v)
        @assert time_value >= 0

        if time_value <= 1
            # Time
            return _time(time_value)
        else
            # DateTime
            return _datetime(time_value, _is_date_1904)
        end
    else
        # Date
        return _date(parse(Int, v), _is_date_1904)
    end
end

"""
Converts Excel number to Time.
`x` must be between 0 and 1.

To represent Time, Excel uses the decimal part
of a floating point number. `1` equals one day.
"""
function _time(x::Float64) :: Dates.Time
    @assert x >= 0 && x <= 1
    return Dates.Time(Dates.Nanosecond(round(Int, x * 86400) * 1E9 ))
end

"""
Converts Excel number to Date.

See also: `isdate1904` function.
"""
function _date(x::Int, _is_date_1904::Bool) :: Dates.Date
    if _is_date_1904
        return Date(Dates.rata2datetime(x + 695056))
    else
        return Date(Dates.rata2datetime(x + 693594))
    end
end

"""
Converts Excel number to DateTime.

The decimal part represents the Time (see `_time` function).
The integer part represents the Date.

See also: `isdate1904` function.
"""
function _datetime(x::Float64, _is_date_1904::Bool) :: Dates.DateTime
    @assert x >= 0

    local dt::Dates.Date
    local hr::Dates.Time

    dt_part = trunc(Int, x)
    hr_part = x - dt_part

    dt = _date(dt_part, _is_date_1904)
    hr = _time(hr_part)

    return dt + hr
end
