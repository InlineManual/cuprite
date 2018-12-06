# frozen_string_literal: true

require "base64"
require "forwardable"
require "cuprite/browser/targets"
require "cuprite/browser/process"
require "cuprite/browser/client"
require "cuprite/browser/page"

module Capybara::Cuprite
  class Browser
    extend Forwardable

    class NullLogger
      def write(_message)
      end
    end

    def self.start(*args)
      new(*args)
    end

    attr_reader :process, :targets
    delegate %i(command subscribe wait) => :@client
    delegate %i(window_handle window_handles switch_to_window open_new_window
                close_window find_window_handle within_window reset page) => :@targets
    delegate %i(evaluate evaluate_async execute) => :@evaluate

    def initialize(options = nil)
      options ||= {}
      @process = Process.start(options)
      @logger = options.fetch(:logger, NullLogger.new)
      @client = Client.new(@process.ws_url, @logger)
      @targets = Targets.new(self, @logger)
      @evaluate = Evaluate.new(@targets)
    end

    def visit(url)
      page.visit(url)
    end

    def current_url
      evaluate("location.href")
    end

    def frame_url
      command "frame_url"
    end

    def status_code
      page.status_code
    end

    def body
      response = page.command("DOM.getDocument", depth: 0)
      response = page.command("DOM.getOuterHTML", nodeId: response["root"]["nodeId"])
      response["outerHTML"]
    end

    def source
      command "source"
    end

    def title
      evaluate("document.title")
    end

    def frame_title
      command "frame_title"
    end

    def parents(target_id, id)
      command "parents", target_id, id
    end

    def find(method, selector)
      find_all(method, selector)
    end

    def find_within(_target_id, node, method, selector)
      resolved = page.command("DOM.resolveNode", nodeId: node["nodeId"])
      object_id = resolved.dig("object", "objectId")
      find_all(method, selector, { "objectId" => object_id })
    end

    def all_text(target_id, node)
      page.evaluate(node, "this.textContent")
    end

    def visible_text(target_id, node)
      begin
        page.evaluate(node, "_cuprite.visibleText(this)")
      rescue BrowserError => e
        # FIXME ObsoleteNode first arg is node, so it should be in node class
        if e.message == "No node with given id found"
          raise ObsoleteNode.new(self, e.response)
        end

        raise
      end
    end

    def delete_text(target_id, id)
      command "delete_text", target_id, id
    end

    def property(_target_id, node, name)
      page.evaluate(node, %Q(this["#{name}"]))
    end

    def attributes(target_id, node)
      value = page.evaluate(node, "_cuprite.getAttributes(this)")
      JSON.parse(value)
    end

    def attribute(target_id, node, name)
      page.evaluate(node, %Q(_cuprite.getAttribute(this, "#{name}")))
    end

    def value(_target_id, node)
      page.evaluate(node, "_cuprite.value(this)")
    end

    def set(target_id, id, value)
      command "set", target_id, id, value
    end

    def select_file(target_id, id, value)
      command "select_file", target_id, id, value
    end

    def tag_name(target_id, node)
      node["nodeName"].downcase
    end

    def visible?(_target_id, node)
      page.evaluate(node, "_cuprite.isVisible(this)")
    end

    def disabled?(_target_id, node)
      page.evaluate(node, "_cuprite.isDisabled(this)")
    end

    def click_coordinates(x, y)
      command "click_coordinates", x, y
    end

    def within_frame(handle)
      if handle.is_a?(Capybara::Node::Base)
        command "push_frame", [handle.native.target_id, handle.native.node]
      else
        command "push_frame", handle
      end

      yield
    ensure
      command "pop_frame"
    end

    def switch_to_frame(handle)
      case handle
      when Capybara::Node::Base
        command "push_frame", [handle.native.target_id, handle.native.node]
      when :parent
        command "pop_frame"
      when :top
        command "pop_frame", true
      end
    end

    def click(target_id, node, keys = [], offset = {})
      x, y, modifiers = prepare_before_click(node, keys, offset)
      page.command("Input.dispatchMouseEvent", type: "mousePressed", modifiers: modifiers, button: "left", x: x, y: y, clickCount: 1)
      page.command("Input.dispatchMouseEvent", type: "mouseReleased", modifiers: modifiers, button: "left", x: x, y: y, clickCount: 1)
    end

    def right_click(target_id, node, keys = [], offset = {})
      x, y, modifiers = prepare_before_click(node, keys, offset)
      page.command("Input.dispatchMouseEvent", type: "mousePressed", modifiers: modifiers, button: "right", x: x, y: y, clickCount: 1)
      page.command("Input.dispatchMouseEvent", type: "mouseReleased", modifiers: modifiers, button: "right", x: x, y: y, clickCount: 1)
    end

    def double_click(target_id, node, keys = [], offset = {})
      x, y, modifiers = prepare_before_click(node, keys, offset)
      page.command("Input.dispatchMouseEvent", type: "mousePressed", modifiers: modifiers, button: "left", x: x, y: y, clickCount: 2)
      page.command("Input.dispatchMouseEvent", type: "mouseReleased", modifiers: modifiers, button: "left", x: x, y: y, clickCount: 2)
    end

    # FIXME: target_id, keys, offset
    def hover(target_id, node)
      x, y = calculate_quads(node)
      page.command("Input.dispatchMouseEvent", type: "mouseMoved", x: x, y: y)
    end

    def drag(target_id, id, other_id)
      command "drag", target_id, id, other_id
    end

    def drag_by(target_id, id, x, y)
      command "drag_by", target_id, id, x, y
    end

    def select(_target_id, node, value)
      page.evaluate(node, "_cuprite.select(this, #{value})")
    end

    def trigger(target_id, id, event)
      command "trigger", target_id, id, event.to_s
    end

    def scroll_to(left, top)
      command "scroll_to", left, top
    end

    def render(path, _options = {})
      # check_render_options!(options)
      # options[:full] = !!options[:full]
      data = Base64.decode64(render_base64)
      File.open(path.to_s, "w") { |f| f.write(data) }
    end

    def render_base64(format = "png", _options = {})
      # check_render_options!(options)
      # options[:full] = !!options[:full]
      page.command("Page.captureScreenshot", format: format)["data"]
    end

    def set_zoom_factor(zoom_factor)
      command "set_zoom_factor", zoom_factor
    end

    def set_paper_size(size)
      command "set_paper_size", size
    end

    def resize(width, height)
      page.resize(width, height)
    end

    def send_keys(target_id, id, keys)
      command "send_keys", target_id, id, normalize_keys(keys)
    end

    def path(target_id, node)
      page.evaluate(node, "_cuprite.path(this)")
    end

    def network_traffic(type = nil)
    end

    def clear_network_traffic
      command("clear_network_traffic")
    end

    def set_proxy(ip, port, type, user, password)
      args = [ip, port, type]
      args << user if user
      args << password if password
      command("set_proxy", *args)
    end

    def get_headers
      command "get_headers"
    end

    def set_headers(headers)
      command "set_headers", headers
    end

    def add_headers(headers)
      command "add_headers", headers
    end

    def add_header(header, options = {})
      command "add_header", header, options
    end

    def response_headers
      command "response_headers"
    end

    def cookies
      Hash[command("cookies").map { |cookie| [cookie["name"], Cookie.new(cookie)] }]
    end

    def set_cookie(cookie)
      cookie[:expires] = cookie[:expires].to_i * 1000 if cookie[:expires]
      command "set_cookie", cookie
    end

    def remove_cookie(name)
      command "remove_cookie", name
    end

    def clear_cookies
      command "clear_cookies"
    end

    def cookies_enabled=(flag)
      command "cookies_enabled", !!flag
    end

    def set_http_auth(user, password)
      command "set_http_auth", user, password
    end

    def page_settings=(settings)
      command "set_page_settings", settings
    end

    def url_whitelist=(whitelist)
      command "set_url_whitelist", *whitelist
    end

    def url_blacklist=(blacklist)
      command "set_url_blacklist", *blacklist
    end

    def clear_memory_cache
      command "clear_memory_cache"
    end

    def go_back
      command "go_back"
    end

    def go_forward
      command "go_forward"
    end

    def refresh
      page.command("Page.reload")
    end

    def accept_confirm
      command "set_confirm_process", true
    end

    def dismiss_confirm
      command "set_confirm_process", false
    end

    def accept_prompt(response)
      command "set_prompt_response", response || false
    end

    def dismiss_prompt
      command "set_prompt_response", nil
    end

    def modal_message
      command "modal_message"
    end

    private

    def check_render_options!(options)
      return if !options[:full] || !options.key?(:selector)
      warn "Ignoring :selector in #render since :full => true was given at #{caller(1..1).first}"
      options.delete(:selector)
    end

    def find_all(method, selector, within = nil)
      begin
        elements = if within
          evaluate("_cuprite.find(arguments[0], arguments[1], arguments[2])", method, selector, within)
        else
          evaluate("_cuprite.find(arguments[0], arguments[1])", method, selector)
        end

        elements.map do |element|
          # nodeType: 3, nodeName: "#text" e.g.
          target_id, node = element.values_at("target_id", "node")
          next if node["nodeType"] != 1
          within ? node : [target_id, node]
        end.compact
      rescue JavaScriptError => e
        if e.class_name == "InvalidSelector"
          raise InvalidSelector.new(e.response, method, selector)
        end
        raise
      end
    end

    def prepare_before_click(node, keys, offset)
      value = page.evaluate(node, "_cuprite.scrollIntoViewport(this)")
      raise MouseEventFailed.new(node, nil) unless value

      x, y = calculate_quads(node, offset[:x], offset[:y])

      click_modifiers = { alt: 1, ctrl: 2, control: 2, meta: 4, command: 4, shift: 8 }
      modifiers = keys.map { |k| click_modifiers[k.to_sym] }.compact.reduce(0, :|)

      page.command("Input.dispatchMouseEvent", type: "mouseMoved", x: x, y: y)

      [x, y, modifiers]
    end

    def calculate_quads(node, offset_x = nil, offset_y = nil)
      quads = get_content_quads(node)
      offset_x, offset_y = offset_x.to_i, offset_y.to_i

      if offset_x > 0 || offset_y > 0
        point = quads.first
        [point[:x] + offset_x, point[:y] + offset_y]
      else
        x, y = quads.inject([0, 0]) do |memo, point|
          [memo[0] + point[:x],
           memo[1] + point[:y]]
        end
        [x / 4, y / 4]
      end
    end

    def get_content_quads(node)
      result = page.command("DOM.getContentQuads", nodeId: node["nodeId"])
      raise "Node is either not visible or not an HTMLElement" if result["quads"].size == 0

      # FIXME: Case when a few quads returned
      result["quads"].map do |quad|
        [{x: quad[0], y: quad[1]},
         {x: quad[2], y: quad[3]},
         {x: quad[4], y: quad[5]},
         {x: quad[6], y: quad[7]}]
      end.first
    end
  end
end
