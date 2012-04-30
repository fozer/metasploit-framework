# ---------------------------------------------------------------------------
#
# This script generates the guides. It can be invoked either directly or via the
# generate_guides rake task within the railties directory.
#
# Guides are taken from the source directory, and the resulting HTML goes into the
# output directory. Assets are stored under files, and copied to output/files as
# part of the generation process.
#
# Some arguments may be passed via environment variables:
#
#   WARNINGS
#     If you are writing a guide, please work always with WARNINGS=1. Users can
#     generate the guides, and thus this flag is off by default.
#
#     Internal links (anchors) are checked. If a reference is broken levenshtein
#     distance is used to suggest an existing one. This is useful since IDs are
#     generated by Textile from headers and thus edits alter them.
#
#     Also detects duplicated IDs. They happen if there are headers with the same
#     text. Please do resolve them, if any, so guides are valid XHTML.
#
#   ALL
#    Set to "1" to force the generation of all guides.
#
#   ONLY
#     Use ONLY if you want to generate only one or a set of guides. Prefixes are
#     enough:
#
#       # generates only association_basics.html
#       ONLY=assoc ruby rails_guides.rb
#
#     Separate many using commas:
#
#       # generates only association_basics.html and migrations.html
#       ONLY=assoc,migrations ruby rails_guides.rb
#
#     Note that if you are working on a guide generation will by default process
#     only that one, so ONLY is rarely used nowadays.
#
#   GUIDES_LANGUAGE
#     Use GUIDES_LANGUAGE when you want to generate translated guides in
#     <tt>source/<GUIDES_LANGUAGE></tt> folder (such as <tt>source/es</tt>).
#     Ignore it when generating English guides.
#
#   EDGE
#     Set to "1" to indicate generated guides should be marked as edge. This
#     inserts a badge and changes the preamble of the home page.
#
#   KINDLE
#     Set to "1" to generate the .mobi with all the guides. The kindlegen
#     executable must be in your PATH. You can get it for free from
#     http://www.amazon.com/kindlepublishing
#
# ---------------------------------------------------------------------------

require 'set'
require 'fileutils'

require 'active_support/core_ext/string/output_safety'
require 'active_support/core_ext/object/blank'
require 'action_controller'
require 'action_view'

require 'rails_guides/indexer'
require 'rails_guides/helpers'
require 'rails_guides/levenshtein'

module RailsGuides
  class Generator
    attr_reader :guides_dir, :source_dir, :output_dir, :edge, :warnings, :all

    GUIDES_RE = /\.(?:textile|erb)$/

    def initialize(output=nil)
      set_flags_from_environment

      if kindle?
        check_for_kindlegen
        register_kindle_mime_types
      end

      initialize_dirs(output)
      create_output_dir_if_needed
    end

    def set_flags_from_environment
      @edge     = ENV['EDGE']     == '1'
      @warnings = ENV['WARNINGS'] == '1'
      @all      = ENV['ALL']      == '1'
      @kindle   = ENV['KINDLE']   == '1'
      @version  = ENV['RAILS_VERSION'] || `git rev-parse --short HEAD`.chomp
      @lang     = ENV['GUIDES_LANGUAGE']
    end

    def register_kindle_mime_types
      Mime::Type.register_alias("application/xml", :opf, %w(opf))
      Mime::Type.register_alias("application/xml", :ncx, %w(ncx))
    end

    def generate
      generate_guides
      copy_assets
      generate_mobi if kindle?
    end

    private

    def kindle?
      @kindle
    end

    def check_for_kindlegen
      if `which kindlegen`.blank?
        raise "Can't create a kindle version without `kindlegen`."
      end
    end

    def generate_mobi
      opf = "#{output_dir}/rails_guides.opf"
      out = "#{output_dir}/kindlegen.out"

      system "kindlegen #{opf} -o #{mobi} > #{out} 2>&1"
      puts "Guides compiled as Kindle book to #{mobi}"
      puts "(kindlegen log at #{out})."
    end

    def mobi
      "ruby_on_rails_guides_#@version%s.mobi" % (@lang.present? ? ".#@lang" : '')
    end

    def initialize_dirs(output)
      @guides_dir = File.join(File.dirname(__FILE__), '..')
      @source_dir = "#@guides_dir/source/#@lang"
      @output_dir = if output
        output
      elsif kindle?
        "#@guides_dir/output/kindle/#@lang"
      else
        "#@guides_dir/output/#@lang"
      end.sub(%r</$>, '')
    end

    def create_output_dir_if_needed
      FileUtils.mkdir_p(output_dir)
    end

    def generate_guides
      guides_to_generate.each do |guide|
        output_file = output_file_for(guide)
        generate_guide(guide, output_file) if generate?(guide, output_file)
      end
    end

    def guides_to_generate
      guides = Dir.entries(source_dir).grep(GUIDES_RE)

      if kindle?
        Dir.entries("#{source_dir}/kindle").grep(GUIDES_RE).map do |entry|
          guides << "kindle/#{entry}"
        end
      end

      ENV.key?('ONLY') ? select_only(guides) : guides
    end

    def select_only(guides)
      prefixes = ENV['ONLY'].split(",").map(&:strip)
      guides.select do |guide|
        prefixes.any? {|p| guide.start_with?(p)}
      end
    end

    def copy_assets
      FileUtils.cp_r(Dir.glob("#{guides_dir}/assets/*"), output_dir)
    end

    def output_file_for(guide)
      if guide =~/\.textile$/
        guide.sub(/\.textile$/, '.html')
      else
        guide.sub(/\.erb$/, '')
      end
    end

    def output_path_for(output_file)
      File.join(output_dir, File.basename(output_file))
    end

    def generate?(source_file, output_file)
      fin  = File.join(source_dir, source_file)
      fout = output_path_for(output_file)
      all || !File.exists?(fout) || File.mtime(fout) < File.mtime(fin)
    end

    def generate_guide(guide, output_file)
      output_path = output_path_for(output_file)
      puts "Generating #{guide} as #{output_file}"
      layout = kindle? ? 'kindle/layout' : 'layout'

      File.open(output_path, 'w') do |f|
        view = ActionView::Base.new(source_dir, :edge => @edge, :version => @version, :mobi => "kindle/#{mobi}")
        view.extend(Helpers)

        if guide =~ /\.(\w+)\.erb$/
          # Generate the special pages like the home.
          # Passing a template handler in the template name is deprecated. So pass the file name without the extension.
          result = view.render(:layout => layout, :formats => [$1], :file => $`)
        else
          body = File.read(File.join(source_dir, guide))
          body = set_header_section(body, view)
          body = set_index(body, view)

          result = view.render(:layout => layout, :text => textile(body))

          warn_about_broken_links(result) if @warnings
        end

        f.write(result)
      end
    end

    def set_header_section(body, view)
      new_body = body.gsub(/(.*?)endprologue\./m, '').strip
      header = $1

      header =~ /h2\.(.*)/
      page_title = "Ruby on Rails Guides: #{$1.strip}"

      header = textile(header)

      view.content_for(:page_title) { page_title.html_safe }
      view.content_for(:header_section) { header.html_safe }
      new_body
    end

    def set_index(body, view)
      index = <<-INDEX
      <div id="subCol">
        <h3 class="chapter"><img src="images/chapters_icon.gif" alt="" />Chapters</h3>
        <ol class="chapters">
      INDEX

      i = Indexer.new(body, warnings)
      i.index

      # Set index for 2 levels
      i.level_hash.each do |key, value|
        link = view.content_tag(:a, :href => key[:id]) { textile(key[:title], true).html_safe }

        children = value.keys.map do |k|
          view.content_tag(:li,
            view.content_tag(:a, :href => k[:id]) { textile(k[:title], true).html_safe })
        end

        children_ul = children.empty? ? "" : view.content_tag(:ul, children.join(" ").html_safe)

        index << view.content_tag(:li, link.html_safe + children_ul.html_safe)
      end

      index << '</ol>'
      index << '</div>'

      view.content_for(:index_section) { index.html_safe }

      i.result
    end

    def textile(body, lite_mode=false)
      t = RedCloth.new(body)
      t.hard_breaks = false
      t.lite_mode = lite_mode
      t.to_html(:notestuff, :plusplus, :code)
    end

    def warn_about_broken_links(html)
      anchors = extract_anchors(html)
      check_fragment_identifiers(html, anchors)
    end

    def extract_anchors(html)
      # Textile generates headers with IDs computed from titles.
      anchors = Set.new
      html.scan(/<h\d\s+id="([^"]+)/).flatten.each do |anchor|
        if anchors.member?(anchor)
          puts "*** DUPLICATE ID: #{anchor}, please put and explicit ID, e.g. h4(#explicit-id), or consider rewording"
        else
          anchors << anchor
        end
      end

      # Footnotes.
      anchors += Set.new(html.scan(/<p\s+class="footnote"\s+id="([^"]+)/).flatten)
      anchors += Set.new(html.scan(/<sup\s+class="footnote"\s+id="([^"]+)/).flatten)
      return anchors
    end

    def check_fragment_identifiers(html, anchors)
      html.scan(/<a\s+href="#([^"]+)/).flatten.each do |fragment_identifier|
        next if fragment_identifier == 'mainCol' # in layout, jumps to some DIV
        unless anchors.member?(fragment_identifier)
          guess = anchors.min { |a, b|
            Levenshtein.distance(fragment_identifier, a) <=> Levenshtein.distance(fragment_identifier, b)
          }
          puts "*** BROKEN LINK: ##{fragment_identifier}, perhaps you meant ##{guess}."
        end
      end
    end
  end
end