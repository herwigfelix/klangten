require 'docx/containers/table_cell'
require 'docx/containers/container'

module Docx
  module Elements
    module Containers
      class TableColumn
        include Container
        include Elements::Element

        def self.tag
          'w:gridCol'
        end

        def initialize(cell_nodes, document_properties = {}, doc = nil)
          @node = ''
          @properties_tag = ''
          @document_properties = document_properties
          @document = doc
          @cells = cell_nodes.map { |c_node| Containers::TableCell.new(c_node, @document_properties, @document) }
        end

        # Array of cells contained within row
        def cells
          @cells
        end
        
      end
    end
  end
end
