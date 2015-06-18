class Crystal::Doc::Generator
  def initialize(@program, @included_dirs, @dir = "./doc")
    @base_dir = `pwd`.chomp
    @types = {} of Crystal::Type => Doc::Type
    @is_crystal_repository = false
    compute_repository
  end

  def run
    Dir.mkdir_p @dir

    types = collect_subtypes(@program)

    program_type = type(@program)
    if program_type.class_methods.any? { |method| must_include? method }
      types.insert 0, program_type
    end

    generate_docs program_type, types
  end

  def generate_docs(program_type, types)
    copy_files
    generate_list types
    generate_types_docs types, @dir
    generate_readme program_type
  end

  def generate_readme(program_type)
    if File.file?("README.md")
      filename = "README.md"
    elsif File.file?("Readme.md")
      filename = "Readme.md"
    end

    if filename
      body = File.read(filename)
    else
      body = ""
    end

    body = String.build do |io|
      Markdown.parse body, MarkdownDocRenderer.new(program_type, io)
    end

    write_template "#{@dir}/main.html", MainTemplate.new(body)
  end

  def copy_files
    Dir.mkdir_p "#{@dir}/css"
    Dir.mkdir_p "#{@dir}/js"

    write_template "#{@dir}/index.html", IndexTemplate.new
    write_template "#{@dir}/css/style.css", StyleTemplate.new
    write_template "#{@dir}/js/type.js", JsTypeTemplate.new
  end

  def generate_list(types)
    write_template "#{@dir}/list.html", ListTemplate.new(types)
  end

  def generate_types_docs(types, dir)
    types.each do |type|
      if type.program?
        filename = "#{dir}/toplevel.html"
      else
        filename = "#{dir}/#{type.name}.html"
      end

      write_template filename, TypeTemplate.new(type)

      next if type.program?

      subtypes = type.types
      if subtypes && !subtypes.empty?
        dirname = "#{dir}/#{type.name}"
        Dir.mkdir_p dirname
        generate_types_docs subtypes, dirname
      end
    end
  end

  def write_template(filename, template)
    File.open(filename, "w") do |file|
      template.to_s file
    end
  end

  def must_include?(type : Doc::Type)
    must_include? type.type
  end

  def must_include?(type : Crystal::IncludedGenericModule)
    must_include? type.module
  end

  def must_include?(type : Crystal::InheritedGenericClass)
    must_include? type.extended_class
  end

  def must_include?(type : Crystal::Type)
    return false if nodoc?(type)

    type.locations.any? do |type_location|
      must_include? type_location
    end
  end

  def must_include?(method : Method)
    must_include? method.def
  end

  def must_include?(a_def : Crystal::Def)
    if @is_crystal_repository && (body = a_def.body).is_a?(Crystal::Primitive)
      doc = Primitive.doc(a_def, body)
      return !nodoc?(doc)
    end
    return false if nodoc?(a_def)

    must_include? a_def.location
  end

  def must_include?(a_macro : Macro)
    must_include? a_macro.macro
  end

  def must_include?(a_macro : Crystal::Macro)
    return false if nodoc?(a_macro)

    must_include? a_macro.location
  end

  def must_include?(location : Crystal::Location)
    case filename = location.filename
    when String
      @included_dirs.any? { |included_dir| filename.starts_with? included_dir }
    when VirtualFile
      must_include? filename.expanded_location
    else
      false
    end
  end

  def must_include?(nil : Nil)
    false
  end

  def nodoc?(str : String?)
    str == ":nodoc:" || str == "nodoc"
  end

  def nodoc?(obj)
    nodoc? obj.doc.try &.strip
  end

  def type(type)
    @types[type] ||= Type.new(self, type)
  end

  def method(type, method, class_method)
    Method.new(self, type, method, class_method)
  end

  def macro(type, a_macro)
    Macro.new(self, type, a_macro)
  end

  def collect_subtypes(parent)
    types = [] of Type

    parent.types.each_value do |type|
      case type
      when Const, LibType
        next
      end

      types << type(type) if must_include? type
    end

    types.sort_by! &.name.downcase
  end

  def collect_constants(parent)
    types = [] of Constant

    parent.type.types.each_value do |type|
      if type.is_a?(Const) && must_include? type
        types << Constant.new(self, parent, type)
      end
    end

    types.sort_by! &.name.downcase unless parent.type.is_a?(EnumType)
    types
  end

  def summary(obj : Type | Method | Macro | Constant)
    doc = obj.doc
    return nil unless doc

    summary obj, doc
  end

  def summary(context, string)
    line = fetch_doc_lines(string).lines.first?
    return nil unless line

    dot_index = line =~ /\.($|\s)/
    if dot_index
      line = line[0 .. dot_index]
    end

    doc context, line
  end

  def doc(obj : Type | Method | Macro | Constant)
    doc = obj.doc
    return nil unless doc

    doc obj, doc
  end

  def doc(context, string)
    String.build do |io|
      Markdown.parse string, MarkdownDocRenderer.new(context, io)
    end
  end

  def fetch_doc_lines(doc)
    doc.gsub /\n+/ do |match|
      if match.length == 1
        " "
      else
        "\n"
      end
    end
  end

  def compute_repository
    remotes = `git remote -v`
    return unless  $?.success?

    remotes.lines.each do |line|
      if line =~ /github\.com(?:\:|\/)((?:\w|-|_)+)\/((?:\w|-|_)+)/
        user, repo = $1, $2
        rev = `git rev-parse HEAD`.chomp

        @repository = "https://github.com/#{user}/#{repo}/blob/#{rev}"

        if user == "manastech" && repo == "crystal"
          @is_crystal_repository = true
        end

        break
      end
    end
  end

  def source_link(node)
    location = relative_location node
    return unless location

    filename = relative_filename location
    return unless filename

    "#{@repository}#{filename}#L#{location.line_number}"
  end

  def relative_location(node : ASTNode)
    relative_location node.location
  end

  def relative_location(location : Location?)
    return unless location

    repository = @repository
    return unless repository

    filename = location.filename
    if filename.is_a?(VirtualFile)
      location = filename.expanded_location
    end

    location
  end

  def relative_filename(location)
    filename = location.filename
    return unless filename.is_a?(String)
    return unless filename.starts_with? @base_dir
    filename[@base_dir.length .. -1]
  end

  record RelativeLocation, filename, url
  SRC_SEP = "src#{File::SEPARATOR}"

  def relative_locations(type)
    repository = @repository
    locations = [] of RelativeLocation
    type.locations.try &.each do |location|
      location = relative_location location
      next unless location

      filename = relative_filename location
      next unless filename

      url = "#{repository}#{filename}" if repository

      filename = filename[1 .. -1] if filename.starts_with? File::SEPARATOR
      filename = filename[4 .. -1] if filename.starts_with? SRC_SEP

      locations << RelativeLocation.new(filename, url)
    end
    locations
  end
end
