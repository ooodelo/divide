require 'sketchup.rb'
require 'set'

module FaceDivider
  unless defined?(@loaded)
    @loaded = true

    TOLERANCE = begin
      0.001.inch
    rescue NoMethodError
      0.001
    end

    MODE_PARALLEL = :parallel
    MODE_GRID = :grid

    MODE_DIALOG_HTML = <<~HTML.freeze
      <!DOCTYPE html>
      <html>
        <head>
          <meta charset="UTF-8">
          <style>
            body {
              font-family: sans-serif;
              margin: 0;
              padding: 16px;
              background: #f6f6f6;
              color: #222;
            }
            h1 {
              font-size: 16px;
              margin-bottom: 12px;
            }
            button {
              display: block;
              width: 100%;
              padding: 10px 12px;
              margin-bottom: 8px;
              font-size: 14px;
              cursor: pointer;
            }
            .hint {
              font-size: 12px;
              margin-top: 12px;
              color: #555;
            }
          </style>
          <script>
            function choose(mode) {
              if (window.sketchup && window.sketchup.selectMode) {
                window.sketchup.selectMode(mode);
              }
            }
          </script>
        </head>
        <body>
          <h1>Выберите режим</h1>
          <button onclick="choose('parallel')">Параллельные линии</button>
          <button onclick="choose('grid')">Прямоугольная сетка</button>
          <div class="hint">Нажмите Escape для отмены.</div>
        </body>
      </html>
    HTML

    def self.start
      model = Sketchup.active_model
      selected_face = model.selection.grep(Sketchup::Face).first
      tool = FaceSelectionTool.new(selected_face)
      model.select_tool(tool)
    end

    def self.create_menu
      return if @menu_created

      UI.menu('Extensions').add_item('Face Divider') { FaceDivider.start }
      @menu_created = true
    end

    create_menu

    def self.create_mode_dialog(&block)
      dialog = UI::HtmlDialog.new(
        dialog_title: 'Режим разделения',
        preferences_key: File.join(PLUGIN_ID, 'mode_dialog'),
        width: 280,
        height: 200,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      dialog.set_html(MODE_DIALOG_HTML)
      dialog.add_action_callback('selectMode') do |_, mode|
        dialog.close
        block.call(mode.to_sym) if block
      end
      dialog
    end

    def self.valid_face?(face)
      face.is_a?(Sketchup::Face) && face.valid?
    end

    class FaceSelectionTool
      def initialize(face = nil)
        @face = face if FaceDivider.valid_face?(face)
        @input_point = Sketchup::InputPoint.new
        @dialog = nil
      end

      def activate
        if @face
          show_dialog
        else
          Sketchup.status_text = 'Выберите грань для разделения.'
        end
      end

      def deactivate(view)
        Sketchup.status_text = ''
        close_dialog
      end

      def onCancel(reason, view)
        close_dialog
        Sketchup.status_text = ''
        Sketchup.active_model.select_tool(nil)
      end

      def onMouseMove(flags, x, y, view)
        return if @dialog

        @input_point.pick(view, x, y)
        view.invalidate
      end

      def draw(view)
        @input_point.draw(view) if @input_point.display?
      end

      def onLButtonDown(flags, x, y, view)
        return if @dialog

        @input_point.pick(view, x, y)
        face = detect_face(view, x, y)
        if face
          @face = face
          show_dialog
        else
          UI.beep
        end
      end

      private

      def show_dialog
        close_dialog
        unless FaceDivider.valid_face?(@face)
          UI.messagebox('Не удалось определить грань.')
          Sketchup.active_model.select_tool(nil)
          return
        end

        @dialog = FaceDivider.create_mode_dialog do |mode|
          @dialog = nil
          start_mode(mode)
        end
        @dialog.show
        Sketchup.status_text = 'Выберите режим разделения.'
      end

      def close_dialog
        return unless @dialog

        @dialog.close if @dialog.visible?
        @dialog = nil
      end

      def start_mode(mode)
        tool = case mode
               when MODE_PARALLEL
                 ParallelLinesTool.new(@face)
               when MODE_GRID
                 GridDivisionTool.new(@face)
               else
                 nil
               end
        if tool
          Sketchup.active_model.select_tool(tool)
        else
          Sketchup.active_model.select_tool(nil)
        end
      end

      def detect_face(view, x, y)
        ph = view.pick_helper
        count = ph.do_pick(x, y)
        (0...count).each do |i|
          path = ph.path_at(i)
          entity = path.find { |item| item.is_a?(Sketchup::Face) }
          return entity if entity
        end
        nil
      end
    end

    class BaseDivisionTool
      attr_reader :face

      def initialize(face)
        @face = face
        @valid = FaceDivider.valid_face?(face)
        @input_point = Sketchup::InputPoint.new
        @preview_segments = []
        @highlight_points = []
        if @valid
          @normal = face.normal.clone
          @normal.normalize!
          @plane = face.plane
          @edge_data = collect_edge_data(face)
          @vertices = collect_vertices(face)
        else
          @normal = Z_AXIS.clone
          @plane = [ORIGIN, Z_AXIS]
          @edge_data = []
          @vertices = []
        end
      end

      def activate
        unless @valid
          UI.messagebox('Выбранная грань недоступна.')
          Sketchup.active_model.select_tool(nil)
          return
        end
        Sketchup.status_text = instruction_text
      end

      def deactivate(view)
        Sketchup.status_text = ''
      end

      def onCancel(reason, view)
        Sketchup.active_model.select_tool(nil)
      end

      def draw(view)
        unless @preview_segments.empty?
          view.line_width = 2
          view.drawing_color = Sketchup::Color.new(0, 120, 215)
          @preview_segments.each do |segment|
            view.draw(GL_LINES, segment)
          end
        end
        unless @highlight_points.empty?
          view.draw_points(@highlight_points, 6, 1, Sketchup::Color.new(255, 128, 0))
        end
        @input_point.draw(view) if @input_point.display?
      end

      private

      def instruction_text
        ''
      end

      def collect_edge_data(face)
        face.loops.flat_map do |loop|
          loop.edges.map do |edge|
            {
              line: edge.line,
              start: edge.start.position,
              end: edge.end.position
            }
          end
        end
      end

      def collect_vertices(face)
        face.loops.flat_map { |loop| loop.vertices.map(&:position) }
      end

      def project_point(point)
        Geom.project_point_to_plane(point, @plane)
      end

      def vector_on_plane(vector)
        vector.project_to_plane(@plane)
      end

      def face_segments(origin, direction)
        return [] if direction.length <= Float::EPSILON

        dir = direction.clone
        dir.normalize!
        line = [origin, dir]
        intersections = []
        @edge_data.each do |edge|
          point = Geom.intersect_line_line(line, edge[:line])
          next unless point
          next unless point_on_segment?(point, edge[:start], edge[:end])

          intersections << point
        end
        return [] if intersections.empty?

        intersections.sort_by! { |pt| (pt - origin).dot(dir) }
        segments = []
        intersections.each_slice(2) do |a, b|
          next unless a && b
          mid = Geom.linear_combination(0.5, a, 0.5, b)
          classification = @face.classify_point(mid)
          segments << [a, b] if inside_face?(classification)
        end
        segments
      end

      def inside_face?(classification)
        allowed = [
          Sketchup::Face::PointInside,
          Sketchup::Face::PointOnEdge,
          Sketchup::Face::PointOnFace
        ]
        allowed.include?(classification)
      end

      def point_on_segment?(point, start_point, end_point)
        total = start_point.distance(end_point)
        return false if total <= TOLERANCE

        distance = start_point.distance(point) + point.distance(end_point)
        (distance - total).abs <= (TOLERANCE * 2.0)
      end

      def set_preview_segments(segments)
        @preview_segments = segments
      end

      def set_highlight_points(points)
        @highlight_points = points
      end

      def finalize_segments(segments, operation_name)
        segments = unique_segments(segments)
        return if segments.empty?

        model = Sketchup.active_model
        model.start_operation(operation_name, true)
        entities = @face.parent.entities
        segments.each do |(a, b)|
          next if a.distance(b) <= TOLERANCE
          begin
            entities.add_line(a, b)
          rescue StandardError
            next
          end
        end
        model.commit_operation
      end

      def unique_segments(segments)
        seen = {}
        segments.each_with_object([]) do |(a, b), result|
          next unless a && b
          next if a.distance(b) <= TOLERANCE

          key = segment_key(a, b)
          next if seen[key]

          seen[key] = true
          result << [a, b]
        end
      end

      def segment_key(a, b)
        coords = [a, b].map do |pt|
          [pt.x.to_f.round(6), pt.y.to_f.round(6), pt.z.to_f.round(6)]
        end
        coords.sort!
        coords.flatten.join(':')
      end

      def index_range(min_val, max_val, step)
        return [0] if step <= 0.0

        min_index = (min_val / step).floor
        max_index = (max_val / step).ceil
        min_index = [min_index, 0].min
        max_index = [max_index, 0].max
        (min_index..max_index).to_a
      end
    end

    class ParallelLinesTool < BaseDivisionTool
      def initialize(face)
        super(face)
        @state = :base_point
        @base_point = nil
        @direction = nil
        @perpendicular = nil
        @offset_min = 0.0
        @offset_max = 0.0
        @current_spacing = nil
        @pending_direction = nil
      end

      def instruction_text
        'Укажите первую точку для базовой линии.'
      end

      def onMouseMove(flags, x, y, view)
        @input_point.pick(view, x, y)
        case @state
        when :base_point
          set_status('Укажите первую точку на грани.')
        when :direction
          update_direction_preview
        when :spacing
          update_spacing_preview
        end
        view.invalidate
      end

      def onLButtonDown(flags, x, y, view)
        @input_point.pick(view, x, y)
        case @state
        when :base_point
          if @input_point.valid?
            @base_point = project_point(@input_point.position)
            set_highlight_points([@base_point])
            @state = :direction
            set_status('Задайте направление базовой линии.')
          else
            UI.beep
          end
        when :direction
          if finalize_direction
            @state = :spacing
            set_status('Задайте шаг между параллельными линиями.')
          else
            UI.beep
          end
        when :spacing
          if @current_spacing && @current_spacing > TOLERANCE
            segments = build_parallel_segments(@current_spacing)
            finalize_segments(segments, 'Разделение граней: параллельные линии')
            Sketchup.active_model.select_tool(nil)
          else
            UI.beep
          end
        end
        view.invalidate
      end

      def onUserText(text, view)
        return unless @state == :spacing

        length = Sketchup.parse_length(text)
        return unless length && length > TOLERANCE

        segments = build_parallel_segments(length)
        finalize_segments(segments, 'Разделение граней: параллельные линии')
        Sketchup.active_model.select_tool(nil)
      end

      private

      def set_status(message)
        Sketchup.status_text = message
      end

      def update_direction_preview
        return unless @base_point
        return unless @input_point.valid?

        point = project_point(@input_point.position)
        vector = vector_on_plane(point - @base_point)
        if vector.length > TOLERANCE
          direction = vector.clone
          direction.normalize!
          @pending_direction = direction
          set_preview_segments(face_segments(@base_point, direction))
        else
          @pending_direction = nil
          set_preview_segments([])
        end
      end

      def finalize_direction
        return false unless @pending_direction

        @direction = @pending_direction.clone
        @perpendicular = @normal.cross(@direction)
        return false if @perpendicular.length <= TOLERANCE

        @perpendicular.normalize!
        compute_offset_range
        set_preview_segments(face_segments(@base_point, @direction))
        true
      end

      def compute_offset_range
        distances = @vertices.map do |vertex|
          vector = @base_point.vector_to(vertex)
          vector.dot(@perpendicular)
        end
        if distances.empty?
          @offset_min = 0.0
          @offset_max = 0.0
        else
          @offset_min = distances.min
          @offset_max = distances.max
        end
      end

      def update_spacing_preview
        return unless @direction && @perpendicular
        return unless @input_point.valid?

        point = project_point(@input_point.position)
        vector = @base_point.vector_to(point)
        offset = vector.dot(@perpendicular)
        spacing = offset.abs
        @current_spacing = spacing
        if spacing > TOLERANCE
          segments = build_parallel_segments(spacing)
          set_preview_segments(segments)
        else
          set_preview_segments(face_segments(@base_point, @direction))
        end
      end

      def build_parallel_segments(spacing)
        return [] unless @direction && @perpendicular
        spacing = spacing.abs
        return face_segments(@base_point, @direction) if spacing <= TOLERANCE

        indices = index_range(@offset_min, @offset_max, spacing)
        segments = []
        indices.each do |i|
          origin = @base_point.offset(@perpendicular, i * spacing)
          segments.concat(face_segments(origin, @direction))
        end
        segments
      end
    end

    class GridDivisionTool < BaseDivisionTool
      def initialize(face)
        super(face)
        @state = :first_corner
        @first_point = nil
        @second_point = nil
        @pending_second_point = nil
        @direction = nil
        @perpendicular = nil
        @length = nil
        @current_width = nil
        @u_min = 0.0
        @u_max = 0.0
        @v_min = 0.0
        @v_max = 0.0
      end

      def instruction_text
        'Укажите первую вершину базового прямоугольника.'
      end

      def onMouseMove(flags, x, y, view)
        @input_point.pick(view, x, y)
        case @state
        when :first_corner
          set_status('Укажите первую вершину прямоугольника.')
        when :second_corner
          update_second_corner_preview
        when :third_corner
          update_width_preview
        end
        view.invalidate
      end

      def onLButtonDown(flags, x, y, view)
        @input_point.pick(view, x, y)
        case @state
        when :first_corner
          if @input_point.valid?
            @first_point = project_point(@input_point.position)
            set_highlight_points([@first_point])
            set_preview_segments([])
            @state = :second_corner
            set_status('Задайте первую сторону прямоугольника.')
          else
            UI.beep
          end
        when :second_corner
          if finalize_second_corner
            @state = :third_corner
            set_status('Задайте ширину прямоугольника.')
          else
            UI.beep
          end
        when :third_corner
          if @current_width && @current_width > TOLERANCE
            segments = build_grid_segments(@length, @current_width)
            finalize_segments(segments, 'Разделение граней: прямоугольная сетка')
            Sketchup.active_model.select_tool(nil)
          else
            UI.beep
          end
        end
        view.invalidate
      end

      def onUserText(text, view)
        return unless @state == :third_corner

        width = Sketchup.parse_length(text)
        return unless width && width > TOLERANCE

        segments = build_grid_segments(@length, width)
        finalize_segments(segments, 'Разделение граней: прямоугольная сетка')
        Sketchup.active_model.select_tool(nil)
      end

      private

      def set_status(message)
        Sketchup.status_text = message
      end

      def update_second_corner_preview
        return unless @first_point
        return unless @input_point.valid?

        point = project_point(@input_point.position)
        vector = vector_on_plane(point - @first_point)
        if vector.length > TOLERANCE
          direction = vector.clone
          length = direction.length
          direction.normalize!
          @pending_second_point = @first_point.offset(direction, length)
          set_preview_segments([[ @first_point, @pending_second_point ]])
        else
          @pending_second_point = nil
          set_preview_segments([])
        end
      end

      def finalize_second_corner
        return false unless @pending_second_point

        @second_point = @pending_second_point
        base_vector = vector_on_plane(@second_point - @first_point)
        @length = base_vector.length
        return false if @length <= TOLERANCE

        @direction = base_vector.clone
        @direction.normalize!
        @perpendicular = @normal.cross(@direction)
        return false if @perpendicular.length <= TOLERANCE

        @perpendicular.normalize!
        compute_projection_ranges
        set_highlight_points([@first_point, @second_point])
        set_preview_segments(build_rectangle_outline(0.0))
        true
      end

      def compute_projection_ranges
        return unless @direction && @perpendicular

        values_u = []
        values_v = []
        @vertices.each do |vertex|
          vector = @first_point.vector_to(vertex)
          values_u << vector.dot(@direction)
          values_v << vector.dot(@perpendicular)
        end
        @u_min, @u_max = values_u.minmax
        @v_min, @v_max = values_v.minmax
        @u_min ||= 0.0
        @u_max ||= 0.0
        @v_min ||= 0.0
        @v_max ||= 0.0
      end

      def update_width_preview
        return unless @second_point && @perpendicular && @direction
        return unless @input_point.valid?

        point = project_point(@input_point.position)
        vector = point - @second_point
        offset = vector.dot(@perpendicular)
        @current_width = offset.abs
        rectangle = build_rectangle_outline(offset)
        if @current_width > TOLERANCE
          grid = build_grid_segments(@length, @current_width)
          set_preview_segments(rectangle + grid)
        else
          set_preview_segments(rectangle)
        end
      end

      def build_rectangle_outline(width_value)
        return [] unless @first_point && @second_point

        p1 = @first_point
        p2 = @second_point
        p3 = p2.offset(@perpendicular, width_value)
        p4 = p1.offset(@perpendicular, width_value)
        [
          [p1, p2],
          [p2, p3],
          [p3, p4],
          [p4, p1]
        ]
      end

      def build_grid_segments(length, width)
        return [] unless length && width
        length = length.abs
        width = width.abs
        return [] if length <= TOLERANCE || width <= TOLERANCE

        u_indices = index_range(@u_min, @u_max, length)
        v_indices = index_range(@v_min, @v_max, width)

        segments = []
        u_indices.each do |i|
          origin = @first_point.offset(@direction, i * length)
          segments.concat(face_segments(origin, @perpendicular))
        end
        v_indices.each do |j|
          origin = @first_point.offset(@perpendicular, j * width)
          segments.concat(face_segments(origin, @direction))
        end
        segments
      end
    end
  end
end
