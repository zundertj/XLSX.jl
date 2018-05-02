
"""
    XLSXFile(filepath)

Creates an empty instance of XLSXFile.
"""
XLSXFile(filepath::AbstractString) = XLSXFile(filepath, Dict{String, EzXML.Document}(), EmptyWorkbook(), Vector{Relationship}())

function readxmldata!(xf, filename)
    xlfile = ZipFile.Reader(xf.filepath)
    for f in xlfile.files
        if f.name == filename
            println("will read $filename")
            doc = EzXML.readxml(f)
            xf.data[f.name] = doc
            println("done reading $filename")

            break
        end
    end

    close(xlfile)
    nothing
end

"""
    read(filepath) :: XLSXFile

Main function for reading an Excel file.
"""
function read(filepath::AbstractString) :: XLSXFile
    @assert isfile(filepath) "File $filepath not found."
    xf = XLSXFile(filepath)

    xlfile = ZipFile.Reader(filepath)
    try
        @sync for f in xlfile.files

            # parse only XML files
            if !ismatch(r".xml", f.name) && !ismatch(r".rels", f.name)
                #warn("Ignoring non-XML file $(f.name).") # debug
                continue
            end

            @async readxmldata!(xf, f.name)
        end

        # Check for minimum package requirements
        check_minimum_requirements(xf)

        parse_relationships!(xf)
        parse_workbook!(xf)

    finally
        close(xlfile)
    end

    return xf
end

get_default_namespace(d::EzXML.Document) = get_default_namespace(EzXML.root(d))

function get_default_namespace(r::EzXML.Node) :: String
    for (prefix, ns) in EzXML.namespaces(r)
        if prefix == ""
            return ns
        end
    end

    error("No default namespace found.")
end

# See section 12.2 - Package Structure
function check_minimum_requirements(xf::XLSXFile)
    mandatory_files = ["_rels/.rels",
                       "xl/workbook.xml",
                       "[Content_Types].xml",
                       "xl/_rels/workbook.xml.rels"
                       ]
 
    for f in mandatory_files
        @assert in(f, filenames(xf)) "Malformed XLSX File. Couldn't find file $f in the package."
    end

    nothing
end

"""
Parses package level relationships defined in `_rels/.rels`.
Prases workbook level relationships defined in `xl/_rels/workbook.xml.rels`.
"""
function parse_relationships!(xf::XLSXFile)
    xroot = xmlroot(xf, "_rels/.rels")
    @assert EzXML.nodename(xroot) == "Relationships" "Malformed XLSX file $(xf.filepath). _rels/.rels root node name should be `Relationships`. Found $(EzXML.nodename(xroot))."
    @assert EzXML.namespaces(xroot) == Pair{String,String}[""=>"http://schemas.openxmlformats.org/package/2006/relationships"]

    for el in EzXML.eachelement(xroot)
        push!(xf.relationships, Relationship(el))
    end
    @assert !isempty(xf.relationships) "Relationships not found in _rels/.rels!"

    xroot = xmlroot(xf, "xl/_rels/workbook.xml.rels")
    @assert EzXML.nodename(xroot) == "Relationships" "Malformed XLSX file $(xf.filepath). xl/_rels/workbook.xml.rels root node name should be `Relationships`. Found $(EzXML.nodename(xroot))."
    @assert EzXML.namespaces(xroot) == Pair{String,String}[""=>"http://schemas.openxmlformats.org/package/2006/relationships"]

    for el in EzXML.eachelement(xroot)
        push!(xf.workbook.relationships, Relationship(el))
    end
    @assert !isempty(xf.workbook.relationships) "Relationships not found in xl/_rels/workbook.xml.rels"

    nothing
end

function parse_shared_strings!(xf::XLSXFile)
    workbook = xf.workbook

    relationship_type = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings"
    if has_relationship_by_type(workbook, relationship_type)
        sst_root = xmlroot(xf, "xl/" * get_relationship_target_by_type(workbook, relationship_type))
        workbook.sst = SharedStrings(sst_root)
    end

    nothing
end

"""
  parse_workbook!(xf::XLSXFile)

Updates xf.workbook from xf.data[\"xl/workbook.xml\"]
"""
function parse_workbook!(xf::XLSXFile)
    xroot = xmlroot(xf, "xl/workbook.xml")
    @assert EzXML.nodename(xroot) == "workbook" "Malformed xl/workbook.xml. Root node name should be 'workbook'. Got '$(EzXML.nodename(xroot))'."

    # workbook to be parsed
    workbook = xf.workbook

    # workbookPr
    local foundworkbookPr::Bool = false
    for node in EzXML.eachelement(xroot)

        if EzXML.nodename(node) == "workbookPr"
            foundworkbookPr = true

            # read date1904 attribute
            if haskey(node, "date1904")
                attribute_value_date1904 = node["date1904"]

                if attribute_value_date1904 == "1" || attribute_value_date1904 == "true"
                    workbook.date1904 = true
                elseif attribute_value_date1904 == "0" || attribute_value_date1904 == "false"
                    workbook.date1904 = false
                else
                    error("Could not parse xl/workbook -> workbookPr -> date1904 = $(attribute_value_date1904).")
                end
            else
                # does not have attribute => is not date1904
                workbook.date1904 = false
            end

            break
        end
    end
    @assert foundworkbookPr "Malformed: couldn't find workbookPr node element in 'xl/workbook.xml'."

    # shared string table
    parse_shared_strings!(xf)

    # sheets
    sheets = Vector{Worksheet}()
    for node in EzXML.eachelement(xroot)
        if EzXML.nodename(node) == "sheets"

            for sheet_node in EzXML.eachelement(node)
                @assert EzXML.nodename(sheet_node) == "sheet" "Unsupported node $(EzXML.nodename(sheet_node)) in 'xl/workbook.xml'."
                worksheet = Worksheet(xf, sheet_node)
                push!(sheets, worksheet)
            end

            break
        end
    end
    workbook.sheets = sheets

    # styles
    STYLES_RELATIONSHIP_TYPE = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles"
    if has_relationship_by_type(workbook, STYLES_RELATIONSHIP_TYPE)
        styles_target = get_relationship_target_by_type(workbook, STYLES_RELATIONSHIP_TYPE)
        workbook.styles = xmldocument(xf, "xl/" * styles_target)

        # check root node name for styles.xml
        styles_root = EzXML.root(workbook.styles)
        @assert get_default_namespace(styles_root) == STYLES_NAMESPACE_XPATH_ARG[1][2] "Unsupported styles XML namespace $(get_default_namespace(styles_root))."
        @assert EzXML.nodename(styles_root) == "styleSheet" "Malformed package. Expected root node named `styleSheet` in `styles.xml`."
    end

    nothing
end
