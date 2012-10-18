#= require underscore
#= require rangy/rangy-core
#= require diff_match_patch
#= require eventemitter2
#= require tandem/document
#= require tandem/range
#= require tandem/keyboard

class TandemEditor extends EventEmitter2
  @editors: []

  @CONTAINER_ID: 'tandem-container'
  @ID_PREFIX: 'editor-'

  @events: 
    API_TEXT_CHANGE       : 'api-text-change'
    USER_SELECTION_CHANGE : 'user-selection-change'
    USER_TEXT_CHANGE      : 'user-text-change'

  options:
    POLL_INTERVAL: 500

  constructor: (@container, enabled = true) ->
    @id = _.uniqueId(TandemEditor.ID_PREFIX)
    @container = document.getElementById(@container) if _.isString(@container)
    this.reset(true)
    this.enable() if enabled

  reset: (keepHTML = false) ->
    @ignoreDomChanges = true
    @iframe = this.createIframe(@container, keepHTML)
    @doc = new Tandem.Document(this, @iframe.contentWindow.document.getElementById(TandemEditor.CONTAINER_ID))
    @currentSelection = null
    @keyboard = new Tandem.Keyboard(this)
    this.initContentListeners()
    this.initSelectionListeners()
    @ignoreDomChanges = false
    TandemEditor.editors.push(this)

  createIframe: (parent, keepHTML) ->
    html = parent.innerHTML
    parent.innerHTML = ''
    iframe = document.createElement('iframe')
    iframe.frameborder = 0
    iframe.src = 'javascript:;'
    iframe.height = iframe.width = '100%'
    parent.appendChild(iframe)
    doc = iframe.contentWindow.document
    head = doc.getElementsByTagName('head')[0]
    style = doc.createElement('style')
    style.type = 'text/css'
    css = "
      body { 
        font-family: 'Helvetica', 'Arial', san-serif;
        font-size: 13px;
        line-height: 15px;
        margin: 0px;
        padding: 10px 15px; 
        white-space: pre;
      }

      ##{TandemEditor.CONTAINER_ID} { min-height: 100%; outline: none; }
      
      a { cursor: pointer; text-decoration: underline; }
      b { font-weight: bold; }
      i { font-style: italic; }
      s { text-decoration: line-through; }
      u { text-decoration: underline; }

      ol, ul { margin: 0px; padding: 0px; }
      ul { list-style-type: disc; }

      ol.indent-1, ol.indent-4, ol.indent-7 { list-style-type: decimal; }
      ol.indent-2, ol.indent-5, ol.indent-8 { list-style-type: lower-alpha; }
      ol.indent-3, ol.indent-6, ol.indent-9 { list-style-type: lower-roman; }

      .font-background.black  { background-color: black; }
      .font-background.red    { background-color: red; }
      .font-background.orange { background-color: orange; }
      .font-background.yellow { background-color: yellow; }
      .font-background.green  { background-color: green; }
      .font-background.blue   { background-color: blue; }
      .font-background.purple { background-color: purple; }
      .font-color.white       { color: white; }
      .font-color.red         { color: red; }
      .font-color.orange      { color: orange; }
      .font-color.yellow      { color: yellow; }
      .font-color.green       { color: green; }
      .font-color.blue        { color: blue; }
      .font-color.purple      { color: purple; }
      .font-family.monospace  { font-family: 'Courier New', monospace; }
      .font-family.serif      { font-family: 'Times New Roman', serif; }
      .font-size.huge         { font-size: 32px; line-height: 36px; }
      .font-size.large        { font-size: 18px; line-height: 22px; }
      .font-size.small        { font-size: 10px; line-height: 12px; }

      .indent-1 { margin-left: 2em; }
      .indent-2 { margin-left: 4em; }
      .indent-3 { margin-left: 6em; }
      .indent-4 { margin-left: 8em; }
      .indent-5 { margin-left: 10em; }
      .indent-6 { margin-left: 12em; }
      .indent-7 { margin-left: 14em; }
      .indent-8 { margin-left: 16em; }
      .indent-9 { margin-left: 18em; }
      
      .tab { display: inline-block; margin: 0px; }
    "
    if style.styleSheet?
      style.styleSheet.cssText = css
    else
      style.appendChild(doc.createTextNode(css))
    head.appendChild(style)
    contentContainer = doc.createElement('div')
    contentContainer.id = Tandem.Editor.CONTAINER_ID
    doc.body.appendChild(contentContainer)
    contentContainer.innerHTML = html if keepHTML
    return iframe

  disable: ->
    @doc.root.setAttribute('contenteditable', false)

  enable: ->
    if !@doc.root.getAttribute('contenteditable')
      @doc.root.setAttribute('contenteditable', true)
      @doc.root.focus()
      position = Tandem.Position.makePosition(this, 0)
      start = new Tandem.Range(this, position, position)
      this.setSelection(start)

  initContentListeners: ->
    onEdit = _.debounce( =>
      delta = this.update()
      if !delta.isIdentity()
        this.checkSelectionChange()
        this.setSelection(@currentSelection)
        this.emit(TandemEditor.events.USER_TEXT_CHANGE, delta)
    , 100)
    @doc.root.addEventListener('DOMSubtreeModified', =>
      return if @ignoreDomChanges
      onEdit()
    )

  initSelectionListeners: ->
    debounceCheckSelectionChange = _.debounce( =>
      this.checkSelectionChange()
    , 100)
    @doc.root.addEventListener('keyup', debounceCheckSelectionChange)
    @doc.root.addEventListener('mouseup', debounceCheckSelectionChange)
    setInterval((=> this.checkSelectionChange()), this.options.POLL_INTERVAL)

  # applyAttribute: (TandemRange range, String attr, Mixed value) ->
  # applyAttribute: (Number startIndex, Number length, String attr, Mixed value) ->
  applyAttribute: (startIndex, length, attr, value, emitEvent = true) ->
    delta = this.trackDelta( =>
      if !_.isNumber(startIndex)
        [range, attr, value] = [startIndex, length, attr]
        startIndex = range.start.getIndex()
        length = range.end.getIndex() - startIndex
      else
        range = new Tandem.Range(this, startIndex, startIndex + length)
      this.preserveSelection(range.start, 0, =>
        [startLine, startLineOffset] = Tandem.Utils.getChildAtOffset(@doc.root, startIndex)
        [endLine, endLineOffset] = Tandem.Utils.getChildAtOffset(@doc.root, startIndex + length)
        if startLine == endLine
          this.applyAttributeToLine(startLine, startLineOffset, endLineOffset, attr, value)
        else
          curLine = startLine.nextSibling
          while curLine? && curLine != endLine
            nextSibling = curLine.nextSibling
            this.applyAttributeToLine(curLine, 0, curLine.textContent.length, attr, value)
            curLine = nextSibling
          this.applyAttributeToLine(startLine, startLineOffset, startLine.textContent.length, attr, value)
          this.applyAttributeToLine(endLine, 0, endLineOffset, attr, value)
        @doc.rebuildDirty()
      )
    , emitEvent)
    this.emit(TandemEditor.events.API_TEXT_CHANGE, delta) if emitEvent

  applyAttributeToLine: (lineNode, startOffset, endOffset, attr, value) ->
    line = @doc.findLine(lineNode)
    if _.indexOf(Tandem.Constants.LINE_ATTRIBUTES, attr, true) > -1
      this.applyLineAttribute(line, attr, value)
    else
      return if startOffset == endOffset
      [prevNode, startNode] = line.splitContents(startOffset)
      [endNode, nextNode] = line.splitContents(endOffset)
      parentNode = startNode.parentNode
      if value && Tandem.Utils.getAttributeDefault(attr) != value
        fragment = @doc.root.ownerDocument.createDocumentFragment()
        Tandem.Utils.traverseSiblings(startNode, endNode, (node) ->
          node = Tandem.Utils.removeAttributeFromSubtree(node, attr)
          fragment.appendChild(node)
        )
        attrNode = Tandem.Utils.createContainerForAttribute(@doc.root.ownerDocument, attr, value)
        attrNode.appendChild(fragment)
        parentNode.insertBefore(attrNode, nextNode)
      else
        Tandem.Utils.traverseSiblings(startNode, endNode, (node) ->
          Tandem.Utils.removeAttributeFromSubtree(node, attr)
        )
    @doc.updateLine(line)
    Tandem.Document.fixListNumbering(@doc.root) if attr == 'list'

  applyDelta: (delta) ->
    console.assert(delta.startLength == @doc.length, "Trying to apply delta to incorrect doc length", delta, @doc, @doc.root)
    index = 0       # Stores where the last retain end was, so if we see another one, we know to delete
    offset = 0      # Tracks how many characters inserted to correctly offset new text
    oldDelta = @doc.toDelta()
    _.each(delta.deltas, (delta) =>
      if JetDelta.isInsert(delta)
        this.insertAt(index + offset, delta.text, false)
        _.each(delta.attributes, (value, attr) =>
          this.applyAttribute(index + offset, delta.text.length, attr, value, false)
        )
        offset += delta.getLength()
      else if JetDelta.isRetain(delta)
        if delta.start > index
          this.deleteAt(index + offset, delta.start - index, false)
          offset -= (delta.start - index)
        deltasInRange = oldDelta.getDeltasAt(delta)
        deltaOffset = 0
        _.each(deltasInRange, (deltaInRange) =>
          attributes = _.extend({}, deltaInRange.attributes, delta.attributes)
          _.each(attributes, (value, attr) =>
            this.applyAttribute(delta.start + offset + deltaOffset, deltaInRange.text.length, attr, value, false)
          )
          deltaOffset += deltaInRange.text.length
        )
        index = delta.end
      else
        console.warn('Unrecognized type in delta', delta)
    )
    # If end of text was deleted
    if delta.endLength < delta.startLength + offset
      this.deleteAt(delta.endLength, delta.startLength + offset - delta.endLength, false)
    newDelta = @doc.toDelta()
    composed = JetSync.compose(oldDelta, delta)
    composed.compact()
    console.assert(_.isEqual(composed, newDelta), oldDelta, delta, composed, newDelta)

  applyLineAttribute: (line, attr, value) ->
    indent = if _.isNumber(value) then value else (if value then 1 else 0)
    if attr == 'indent'
      Tandem.Utils.setIndent(line.node, indent)
    else if Tandem.Constants.INDENT_ATTRIBUTES[attr]?
      lineNode = line.node
      expectedTag = if value then (if attr == 'list' then 'OL' else 'UL') else 'DIV'
      if lineNode.tagName != expectedTag
        if value && lineNode.firstChild.tagName != 'LI'
          li = lineNode.ownerDocument.createElement('li')
          Tandem.Utils.wrapChildren(li, lineNode)
        else if !value && lineNode.firstChild.tagName == 'LI'
          Tandem.Utils.unwrap(lineNode.firstChild)
        line.node = Tandem.Utils.switchTag(lineNode, expectedTag)
      Tandem.Utils.setIndent(line.node, indent)
    line.setDirty()

  checkSelectionChange: ->
    return if @ignoreDomChanges
    selection = this.getSelection()
    if selection != @currentSelection && ((selection? && !selection.equals(@currentSelection)) || !@currentSelection.equals(selection))
      this.emit(TandemEditor.events.USER_SELECTION_CHANGE, selection)
      @currentSelection = selection

  deleteAt: (startIndex, length, emitEvent = true) ->
    delta = this.trackDelta( =>
      if !_.isNumber(startIndex)
        range = startIndex
        startPos = range.start
        endPos = range.end
        startIndex = range.start.getIndex()
        length = range.end.getIndex() - startIndex
      else
        startPos = Tandem.Position.makePosition(this, startIndex)
        endPos = Tandem.Position.makePosition(this, startIndex + length)
      startIndex = startPos.getIndex()
      endIndex = endPos.getIndex()
      this.preserveSelection(startPos, 0 - length, =>
        [startLineNode, startOffset] = Tandem.Utils.getChildAtOffset(@doc.root, startIndex)
        [endLineNode, endOffset] = Tandem.Utils.getChildAtOffset(@doc.root, endIndex)
        fragment = Tandem.Utils.extractNodes(startLineNode, startOffset, endLineNode, endOffset)
        lineNodes = _.values(fragment.childNodes).concat(_.uniq([startLineNode, endLineNode]))
        _.each(lineNodes, (lineNode) =>
          line = @doc.findLine(lineNode)
          @doc.updateLine(line) if line?
        )
        @doc.rebuildDirty()
      )
    , emitEvent)
    this.emit(TandemEditor.events.API_TEXT_CHANGE, delta) if emitEvent

  getAt: (startIndex, length) ->
    # - Returns array of {text: "", attr: {}}
    # 1. Get all nodes in the range
    # 2. For first and last, change the text
    # 3. Return array
    # - Helper to get nodes in given index range
    # - In the case of 0 lenght, text will always be "", but attributes should be properly applied

  getDelta: ->
    return @doc.toDelta()

  getSelection: ->
    return Tandem.Range.getSelection(this)

  insertAt: (startIndex, text, emitEvent = true) ->
    delta = this.trackDelta( =>
      position = Tandem.Position.makePosition(this, startIndex)
      index = startIndex = position.getIndex()
      startLine = @doc.findLineAtOffset(index)
      attr = if startLineNode? then startLine.attributes else {}
      this.preserveSelection(position, text.length, =>
        lines = text.split("\n")
        _.each(lines, (line, lineIndex) =>
          strings = line.split("\t")
          _.each(strings, (str, strIndex) =>
            this.insertTextAt(index, str)
            index += str.length
            if strIndex < strings.length - 1
              this.insertTabAt(index)
              index += 1
          )
          if lineIndex < lines.length - 1
            this.insertNewlineAt(index)
            index += 1
          else
            # TODO could be more clever about if we need to call this
            Tandem.Document.fixListNumbering(@doc.root)
        )
        @doc.rebuildDirty()
      )
    , emitEvent)
    this.emit(TandemEditor.events.API_TEXT_CHANGE, delta) if emitEvent

  insertNewlineAt: (startIndex) ->
    [line, offset] = @doc.findLineAtOffset(startIndex)
    newLine = @doc.splitLine(line, offset)
    # TODO we need to do this for each line attribute... find more elegant solution
    this.applyLineAttribute(newLine, 'list', false) if line.attributes.list
    this.applyLineAttribute(newLine, 'bullet', false) if line.attributes.bullet
    this.applyLineAttribute(newLine, 'indent', false) if line.attributes.indent

  insertTabAt: (startIndex) ->
    [startLineNode, startLineOffset] = Tandem.Utils.getChildAtOffset(@doc.root, startIndex)
    startLine = @doc.findLine(startLineNode)
    [prevNode, startNode] = startLine.splitContents(startLineOffset)
    tab = startLineNode.ownerDocument.createElement('span')
    tab.classList.add(Tandem.Leaf.TAB_NODE_CLASS)
    parentNode = prevNode?.parentNode || startNode?.parentNode
    parentNode.insertBefore(tab, startNode)
    @doc.updateLine(startLine)

  # insertTextAt: (Number startIndex, String text) ->
  # insertTextAt: (TandemRange startIndex, String text) ->
  insertTextAt: (startIndex, text) ->
    return if text.length <= 0
    position = Tandem.Position.makePosition(this, startIndex)
    startIndex = position.getIndex()
    leaf = position.getLeaf()
    if _.keys(leaf.attributes).length > 0 || Tandem.Utils.isIgnoreNode(leaf.node)
      [lineNode, lineOffset] = Tandem.Utils.getChildAtOffset(@doc.root, startIndex)
      [beforeNode, afterNode] = leaf.line.splitContents(lineOffset)
      parentNode = beforeNode?.parentNode || afterNode?.parentNode
      span = lineNode.ownerDocument.createElement('span')
      span.textContent = text
      parentNode.insertBefore(span, afterNode)
    else
      if leaf.node.nodeName == 'BR'
        parent = leaf.node.parentNode
        parent.removeChild(leaf.node)
        leaf.node = parent.ownerDocument.createElement('span')
        leaf.setText(text)
        parent.appendChild(leaf.node)
      else
        leaf.setText(leaf.node.textContent.substr(0, position.offset) + text + leaf.node.textContent.substr(position.offset))
    @doc.updateLine(leaf.line)

  preserveSelection: (modPosition, charAdditions, fn) ->
    selection = Tandem.Range.getSelection(this)
    if selection?
      isBodyChild = (node) -> return node.parentNode?.id == TandemEditor.CONTAINER_ID
      isBlockTag = (node) -> return _.indexOf(Tandem.Constants.BLOCK_TAGS, node.tagName, true) > -1
      startBlock = Tandem.Utils.findAncestor(selection.start.leafNode, isBlockTag)
      endBlock = Tandem.Utils.findAncestor(selection.end.leafNode, isBlockTag)
      return fn() if !startBlock? || !endBlock?
      startLine = Tandem.Utils.findAncestor(startBlock, isBodyChild)
      endLine = Tandem.Utils.findAncestor(endBlock, isBodyChild)
      startBlockOffset = Tandem.Position.getIndex(selection.start.leafNode, selection.start.offset, startBlock)
      endBlockOffset = Tandem.Position.getIndex(selection.end.leafNode, selection.end.offset, endBlock)
      startLineOffset = Tandem.Position.getIndex(startBlock, 0, startLine) + startBlockOffset
      endLineOffset = Tandem.Position.getIndex(endBlock, 0, endLine) + endBlockOffset
      fn()
      if startBlock.parentNode?
        startPos = new Tandem.Position(this, startBlock, startBlockOffset)
      else
        startLine = startLine.ownerDocument.getElementById(startLine.id) if startLine.parentNode == null
        startPos = new Tandem.Position(this, startLine, startLineOffset)
      if endBlock.parentNode?
        endPos = new Tandem.Position(this, startBlock, startBlockOffset)
      else
        endLine = endLine.ownerDocument.getElementById(endLine.id) if endLine.parentNode == null
        endPos = new Tandem.Position(this, endLine, endLineOffset)
      savedSelectionRange = new Tandem.Range(this, startPos, endPos)
      [selStart, selEnd] = this.transformSelection(modPosition, savedSelectionRange, charAdditions)
      savedSelectionRange = new Tandem.Range(this, Tandem.Position.makePosition(this, selStart), Tandem.Position.makePosition(this, selEnd))
      this.setSelection(savedSelectionRange)
      this.checkSelectionChange()
    else
      fn()

  setSelection: (range) ->
    Tandem.Range.setSelection(this, range)

  # TODO use node.compareDocumentPosition for efficiency
  transformSelection: (modPosition, selectionRange, charAdditions) ->
    modPos = if modPosition? then modPosition.getIndex() else 0
    selStart = selectionRange.start.getIndex()
    selEnd = selectionRange.end.getIndex()
    selStart = Math.max(selStart + charAdditions, modPos) if modPos <= selStart
    selEnd = Math.max(selEnd + charAdditions, modPos) if modPos < selEnd
    selEnd = Math.max(selStart, selEnd)
    return [selStart, selEnd]

  trackDelta: (fn, track = true) ->
    oldIgnoreDomChange = @ignoreDomChanges
    @ignoreDomChanges = true
    delta = null
    if track
      oldDelta = @doc.toDelta()
      fn()
      newDelta = @doc.toDelta()
      decompose = JetSync.decompose(oldDelta, newDelta)
      compose = JetSync.compose(oldDelta, decompose)
      console.assert(_.isEqual(compose, newDelta), oldDelta, newDelta, decompose, compose)
      delta = decompose
    else
      fn()
    @ignoreDomChanges = oldIgnoreDomChange
    return delta

  update: ->
    return this.trackDelta( =>
      this.preserveSelection(null, 0, =>
        Tandem.Document.normalizeHtml(@doc.root)
        lines = @doc.lines.toArray()
        lineNode = @doc.root.firstChild
        _.each(lines, (line, index) =>
          while line.node != lineNode
            if line.node.parentNode == @doc.root
              newLine = @doc.insertLineBefore(lineNode, line)
              lineNode = lineNode.nextSibling
            else
              @doc.removeLine(line)
              return
          @doc.updateLine(line)
          lineNode = lineNode.nextSibling
        )
        while lineNode != null
          newLine = @doc.appendLine(lineNode)
          lineNode = lineNode.nextSibling
      )
    , true)
    return



window.Tandem ||= {}
window.Tandem.Editor = TandemEditor
