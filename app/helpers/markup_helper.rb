require 'nokogiri'

module MarkupHelper
  def plain?(filename)
    Gitlab::MarkupHelper.plain?(filename)
  end

  def markup?(filename)
    Gitlab::MarkupHelper.markup?(filename)
  end

  def gitlab_markdown?(filename)
    Gitlab::MarkupHelper.gitlab_markdown?(filename)
  end

  def asciidoc?(filename)
    Gitlab::MarkupHelper.asciidoc?(filename)
  end

  # Use this in places where you would normally use link_to(gfm(...), ...).
  #
  # It solves a problem occurring with nested links (i.e.
  # "<a>outer text <a>gfm ref</a> more outer text</a>"). This will not be
  # interpreted as intended. Browsers will parse something like
  # "<a>outer text </a><a>gfm ref</a> more outer text" (notice the last part is
  # not linked any more). link_to_gfm corrects that. It wraps all parts to
  # explicitly produce the correct linking behavior (i.e.
  # "<a>outer text </a><a>gfm ref</a><a> more outer text</a>").
  def link_to_gfm(body, url, html_options = {})
    return '' if body.blank?

    context = {
      project: @project,
      current_user: (current_user if defined?(current_user)),
      pipeline: :single_line,
    }
    gfm_body = Banzai.render(body, context)

    fragment = Nokogiri::HTML::DocumentFragment.parse(gfm_body)
    if fragment.children.size == 1 && fragment.children[0].name == 'a'
      # Fragment has only one node, and it's a link generated by `gfm`.
      # Replace it with our requested link.
      text = fragment.children[0].text
      fragment.children[0].replace(link_to(text, url, html_options))
    else
      # Traverse the fragment's first generation of children looking for pure
      # text, wrapping anything found in the requested link
      fragment.children.each do |node|
        next unless node.text?
        node.replace(link_to(node.text, url, html_options))
      end
    end

    # Add any custom CSS classes to the GFM-generated reference links
    if html_options[:class]
      fragment.css('a.gfm').add_class(html_options[:class])
    end

    fragment.to_html.html_safe
  end

  # Return the first line of +text+, up to +max_chars+, after parsing the line
  # as Markdown.  HTML tags in the parsed output are not counted toward the
  # +max_chars+ limit.  If the length limit falls within a tag's contents, then
  # the tag contents are truncated without removing the closing tag.
  def first_line_in_markdown(text, max_chars = nil, options = {})
    md = markdown(text, options).strip

    truncate_visible(md, max_chars || md.length) if md.present?
  end

  def markdown(text, context = {})
    return '' unless text.present?

    context[:project] ||= @project
    html = markdown_unsafe(text, context)
    banzai_postprocess(html, context)
  end

  def markdown_field(object, field)
    object = object.for_display if object.respond_to?(:for_display)
    return '' unless object.present?

    html = Banzai.render_field(object, field)
    banzai_postprocess(html, object.banzai_render_context(field))
  end

  def markup(file_name, text, context = {})
    context[:project] ||= @project
    html = context.delete(:rendered) || markup_unsafe(file_name, text, context)
    banzai_postprocess(html, context)
  end

  def render_wiki_content(wiki_page)
    text = wiki_page.content
    return '' unless text.present?

    context = { pipeline: :wiki, project: @project, project_wiki: @project_wiki, page_slug: wiki_page.slug }

    html =
      case wiki_page.format
      when :markdown
        markdown_unsafe(text, context)
      when :asciidoc
        asciidoc_unsafe(text)
      else
        wiki_page.formatted_content.html_safe
      end

    banzai_postprocess(html, context)
  end

  def markup_unsafe(file_name, text, context = {})
    return '' unless text.present?

    if gitlab_markdown?(file_name)
      Hamlit::RailsHelpers.preserve(markdown_unsafe(text, context))
    elsif asciidoc?(file_name)
      asciidoc_unsafe(text)
    elsif plain?(file_name)
      content_tag :pre, class: 'plain-readme' do
        text
      end
    else
      other_markup_unsafe(file_name, text)
    end
  rescue RuntimeError
    simple_format(text)
  end

  # Returns the text necessary to reference `entity` across projects
  #
  # project - Project to reference
  # entity  - Object that responds to `to_reference`
  #
  # Examples:
  #
  #   cross_project_reference(project, project.issues.first)
  #   # => 'namespace1/project1#123'
  #
  #   cross_project_reference(project, project.merge_requests.first)
  #   # => 'namespace1/project1!345'
  #
  # Returns a String
  def cross_project_reference(project, entity)
    if entity.respond_to?(:to_reference)
      entity.to_reference(project, full: true)
    else
      ''
    end
  end

  private

  # Return +text+, truncated to +max_chars+ characters, excluding any HTML
  # tags.
  def truncate_visible(text, max_chars)
    doc = Nokogiri::HTML.fragment(text)
    content_length = 0
    truncated = false

    doc.traverse do |node|
      if node.text? || node.content.empty?
        if truncated
          node.remove
          next
        end

        # Handle line breaks within a node
        if node.content.strip.lines.length > 1
          node.content = "#{node.content.lines.first.chomp}..."
          truncated = true
        end

        num_remaining = max_chars - content_length
        if node.content.length > num_remaining
          node.content = node.content.truncate(num_remaining)
          truncated = true
        end
        content_length += node.content.length
      end

      truncated = truncate_if_block(node, truncated)
    end

    doc.to_html
  end

  # Used by #truncate_visible.  If +node+ is the first block element, and the
  # text hasn't already been truncated, then append "..." to the node contents
  # and return true.  Otherwise return false.
  def truncate_if_block(node, truncated)
    return true if truncated

    if node.element? && (node.description&.block? || node.matches?('pre > code > .line'))
      node.inner_html = "#{node.inner_html}..." if node.next_sibling
      true
    else
      truncated
    end
  end

  def markdown_toolbar_button(options = {})
    data = options[:data].merge({ container: 'body' })
    content_tag :button,
      type: 'button',
      class: 'toolbar-btn js-md has-tooltip hidden-xs',
      tabindex: -1,
      data: data,
      title: options[:title],
      aria: { label: options[:title] } do
      icon(options[:icon])
    end
  end

  def markdown_unsafe(text, context = {})
    Banzai.render(text, context)
  end

  def asciidoc_unsafe(text)
    Gitlab::Asciidoc.render(text)
  end

  def other_markup_unsafe(file_name, text)
    Gitlab::OtherMarkup.render(file_name, text)
  end

  # Calls Banzai.post_process with some common context options
  def banzai_postprocess(html, context = {})
    return '' unless html.present?

    context.merge!(
      current_user:   (current_user if defined?(current_user)),

      # RelativeLinkFilter
      commit:         @commit,
      project_wiki:   @project_wiki,
      ref:            @ref,
      requested_path: @path
    )

    Banzai.post_process(html, context)
  end
end
