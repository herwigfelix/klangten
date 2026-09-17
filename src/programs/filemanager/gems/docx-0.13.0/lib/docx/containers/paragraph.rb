require 'docx/containers/text_run'
require 'docx/containers/container'

module Docx
  module Elements
    module Containers
      class Paragraph
        include Container
        include Elements::Element

        def self.tag
          'p'
        end


        # Child elements: pPr, r, fldSimple, hlink, subDoc
        # http://msdn.microsoft.com/en-us/library/office/ee364458(v=office.11).aspx
        def initialize(node, document_properties = {}, doc = nil)
          @node = node
          @properties_tag = 'pPr'
          @document_properties = document_properties
          @font_size = @document_properties[:font_size]
          @document = doc
        end

        # Set text of paragraph
        def text=(content)
          if text_runs.size == 1
            text_runs.first.text = content
          elsif text_runs.size == 0
            new_r = TextRun.create_within(self)
            new_r.text = content
          else
            text_runs.each {|r| r.node.remove }
            new_r = TextRun.create_within(self)
            new_r.text = content
          end
        end

        # Return text of paragraph
        def to_s
          text_runs.map(&:text).join('')
        end

        # Return paragraph as a <p></p> HTML fragment with formatting based on properties.
        def to_html
          html = +''
          text_runs.each do |text_run|
            html << text_run.to_html
          end
          styles = { 'font-size' => "#{font_size}pt" }
          styles['color'] = "##{font_color}" if font_color
          styles['text-align'] = alignment if alignment
          html_tag(:p, content: html, styles: styles)
        end


        # Array of text runs contained within paragraph
        def text_runs
          @node.xpath('w:r|w:hyperlink').map { |r_node| Containers::TextRun.new(r_node, @document_properties) }
        end

        # Iterate over each text run within a paragraph
        def each_text_run
          text_runs.each { |tr| yield(tr) }
        end

        # Substitute text within the paragraph, even when a match spans multiple
        # text runs (e.g. a "{{placeholder}}" that Word split across several runs,
        # such as "{{fi", "rst_na", "me}}"). The per-run TextRun#substitute cannot
        # match those, but this can, because it joins the runs first.
        #
        # The matched region is collapsed into the first run it touches, so that
        # run's formatting is kept while the other spanned runs are emptied; runs
        # outside the match are left untouched.
        #
        # +pattern+ may be a String or a Regexp; +replacement+ follows String#sub
        # semantics, so capture-group backreferences (e.g. '\1') work with a Regexp.
        #
        #   # given a paragraph reading "Hello {{first_name}}!"
        #   paragraph.substitute('{{first_name}}', 'Jane')   # => "Hello Jane!"
        #   paragraph.substitute(/\{\{(\w+)\}\}/, 'value of \1')
        #
        # See https://github.com/ruby-docx/docx/issues/147
        def substitute(pattern, replacement)
          search_from = 0
          loop do
            runs = text_runs
            break if runs.empty?

            offsets = []
            cursor = 0
            runs.each do |run|
              offsets << cursor
              cursor += run.text.length
            end
            full_text = runs.map(&:text).join

            match = full_text.match(pattern, search_from)
            break unless match
            break if match.end(0) == match.begin(0) # ignore empty matches

            match_start = match.begin(0)
            match_end   = match.end(0) # exclusive
            first = offsets.rindex { |offset| offset <= match_start }
            last  = offsets.rindex { |offset| offset < match_end }

            combined = runs[first..last].map(&:text).join
            local_start = match_start - offsets[first]
            local_end   = match_end - offsets[first]
            replaced = combined[local_start...local_end].sub(pattern, replacement)
            runs[first].text = combined[0...local_start] + replaced + combined[local_end..-1]
            ((first + 1)..last).each { |index| runs[index].text = '' }

            # advance past the inserted replacement so it is not re-matched
            search_from = match_start + replaced.length
          end
          self
        end

        def aligned_left?
          ['left', nil].include?(alignment)
        end

        def aligned_right?
          alignment == 'right'
        end

        def aligned_center?
          alignment == 'center'
        end

        def font_size
          size_attribute = @node.at_xpath('w:pPr//w:sz//@w:val')

          return @font_size unless size_attribute

          size_attribute.value.to_i / 2
        end

        def font_color
          color_tag = @node.xpath('w:r//w:rPr//w:color').first
          color_tag ? color_tag.attributes['val']&.value : nil
        end

        def style
          return nil unless @document

          @document.style_name_of(style_id) ||
            @document.default_paragraph_style
        end

        def style_id
          style_property.get_attribute('w:val')
        end

        def style=(identifier)
          id = @document.styles_configuration.style_of(identifier).id

          style_property.set_attribute('w:val', id)
        end

        alias_method :style_id=, :style=
        alias_method :text, :to_s

        private

        def style_property
          properties&.at_xpath('w:pStyle') || properties&.add_child('<w:pStyle/>').first
        end

        # Returns the alignment if any, or nil if left
        def alignment
          @node.at_xpath('.//w:jc/@w:val')&.value
        end
      end
    end
  end
end
