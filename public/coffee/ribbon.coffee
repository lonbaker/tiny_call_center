store = {
  calls: {}
  send: (obj) -> @ws.send(JSON.stringify(obj))
}

# Expand as you need it.
keyCodes = {
  F1:  112,
  F2:  113,
  F3:  114,
  F4:  115,
  F5:  116,
  F6:  117,
  F7:  118,
  F8:  119,
  F9:  120,
  F10: 121,
  F11: 122,
  F12: 123,
}

p = ->
  window.console?.debug?(arguments)

showError = (msg) ->
  $('#error').text(msg)

divmod = (num1, num2) ->
  [num1 / num2, num1 % num2]

formatInterval = (start) ->
  total   = parseInt((Date.now() - start) / 1000, 10)
  [hours, rest] = divmod(total, 60 * 60)
  [minutes, seconds] = divmod(rest, 60)
  sprintf("%02d:%02d:%02d", hours, minutes, seconds)

formatPhoneNumber = (number) ->
  return number unless number?
  md = number.match(/^(\d{3})(\d{3})(\d{4})/)
  return number unless md?
  "(#{md[1]})-#{md[2]}-#{md[3]}"

class Call
  constructor: (local_leg, remote_leg, msg) ->
    @uuid = remote_leg.uuid
    @local_leg = local_leg
    @remote_leg = remote_leg
    store.calls[@uuid] = this
    @prepareDOM()
    @talkingStart(new Date(Date.parse(msg.call_created)))

  prepareDOM: ->
    @sel = store.call_template.clone()
    @sel.attr('id', '')
    $('#calls').append(@sel)

    @dom = {
      cidNumber:   $('.cid-number', @sel),
      cidName:     $('.cid-name', @sel),
      answered:    $('.answered', @sel),
      called:      $('.called', @sel),
      destination: $('.destination', @sel),
      queueName:   $('.queue-name', @sel),
      uuid:        $('.uuid', @sel),
      channel:     $('.channel', @sel),
    }

    @dom.cidNumber.text(formatPhoneNumber(@remote_leg.cid_number))
    @dom.cidName.text(@remote_leg.cid_name)
    @dom.destination.text(formatPhoneNumber(@remote_leg.destination))
    @dom.queueName.text(@local_leg.queue)
    @dom.uuid.text(@remote_leg.uuid)
    @dom.channel.text(@local_leg.channel)

    $('.dtmf-form', @sel).submit (event) =>
      input = $('.dtmf-input', $(event.target))
      val = input.val()
      store.send(method: 'dtmf', uuid: @uuid, dtmf: val)
      input.val('')
      false

  'bridge-agent-start': (msg) ->
    @dom.cidName.text(msg.cc_caller_cid_name)
    @dom.cidNumber.text(formatPhoneNumber(msg.cc_caller_cid_number))
    @talkingStart(new Date(Date.now()))

  'bridge-agent-end': (msg) ->
    @talkingEnd()

  channel_hangup: (msg) ->
    @talkingEnd()

  channel_answer: (msg) ->
    if msg.caller_destination_number == store.agent_ext
      @answeredCall(
        'Inbound Call',
        msg.caller_caller_id_name,
        msg.caller_caller_id_number,
        msg.channel_call_uuid || msg.unique_id
      )
    else if msg.caller_caller_id_number == store.agent_ext
      @answeredCall(
        'Outbound Call',
        msg.caller_destination_number,
        msg.caller_callee_id_number,
        msg.channel_call_uuid || msg.unique_id
      )

  answeredCall: (cidName, cidNumber, uuid) ->
    @dom.cidNumber.text(cidNumber)
    @dom.cidName.text(cidName) if cidName?
    @talkingStart(new Date(Date.now()))

  talkingStart: (answeredTime) ->
    return if @answered?
    @answered = answeredTime || new Date(Date.now())
    @answeredInterval = setInterval =>
      @dom.answered.text(
        "#{@answered.toLocaleTimeString()} #{formatInterval(@answered)}"
      )
    , 1000

  talkingEnd: ->
    clearInterval(@answeredInterval)
    delete store.calls[@uuid]
    @askDisposition()
    @sel.remove()

  askDisposition: ->
    return # Disable Dispositions Until We Allow It To Be Optional
    if @local_leg.cid_number == "8675309" || @local_leg.destination == "19999"
      return

    $('#disposition button').one 'click', (event) =>
      jbutton = $(event.target)
      store.send(
        method: 'disposition',
        code:  jbutton.attr('id').split('-')[1],
        desc:  jbutton.attr('label'),
        left: @local_leg,
        right: @remote_leg,
      )
      $('#disposition').hide()
      return false
    $('#disposition').show()

currentStatus = (tag) ->
  $('.change-status').removeClass('active inactive')
  tag.addClass('active')

agentStatusChange = (msg) ->
  switch msg.cc_agent_status.toLowerCase()
    when 'available', 'available (on demand)'
      currentStatus($('#available'))
    when 'on break'
      currentStatus($('#on_break'))
    when 'logged out'
      currentStatus($('#logged_out'))

currentState = (tag) ->
  $('.change-state').removeClass('active inactive')
  tag.addClass('active')

agentStateChange = (msg) ->
  state = msg.cc_agent_state.replace(/\s+/g, "_")
  currentState($("##{state}"))

onMessage = (event) ->
  msg = JSON.parse(event.data)
  p msg
  switch msg.tiny_action
    when 'status_change'
      agentStatusChange(msg)
    when 'state_change'
      agentStateChange(msg)
    when 'call_start'
      extMatch = /(?:^|\/)(?:sip:)?(\d+)[@-]/
      makeCall = (left, right, msg) ->
        uuid = right.uuid
        if store.calls[uuid]
          p "Found duplicate Call", store.calls[uuid]
        else
          call = new Call(left, right, msg)
          p "Created Call", call

      if store.agent_ext == msg.left.channel?.match?(extMatch)?[1]
        makeCall(msg.left, msg.right, msg)
      else if store.agent_ext == msg.right.channel?.match?(extMatch)?[1]
        makeCall(msg.right, msg.left, msg)
      else if msg.right.destination == msg.right.channel?.match?(extMatch)?[1]
        makeCall(msg.right, msg.left, msg)
      else if msg.left.destination == msg.left.channel?.match?(extMatch)?[1]
        makeCall(msg.left, msg.right, msg)
      else if msg.left.cid_number == msg.left.channel?.match?(extMatch)?[1]
        makeCall(msg.left, msg.right, msg)
      else if msg.right.cid_number == msg.right.channel?.match?(extMatch)?[1]
        makeCall(msg.right, msg.left, msg)
    else
      for key, value of msg
        if /unique|uuid/.test(key)
          #p [key, value]
          if call = store.calls[value]
            call[msg.tiny_action]?(msg)
            return undefined
  if $.isEmptyObject(store.calls)
    $('#callme').show()
  else
    $('#callme').hide()

onOpen = ->
  store.send(method: 'subscribe', agent: store.agent_name)

onClose = ->
  $('#debug').text('Reconnecting...')
  setTimeout ->
    $('#debug').text('')
    setupWs()
  , 5000

onError = (event) ->
  showError(event.data)

agentWantsStatusChange = (a) ->
  curStatus = $('.change-status[class=active]').text()
  store.send(
    method: 'status',
    status: a.target.id,
    curStatus: curStatus
  )
  false

agentWantsStateChange = (a) ->
  curState = $('.change-state[class=active]').text()
  store.send(
    method: 'state',
    state: a.target.id.replace(/_/g, ' '),
    curState: curState,
  )
  false

agentWantsToBeCalled = (event) =>
  store.send(method: 'callme')
  false

agentWantsCallHangup = (event) ->
  call_div = $(event.target).closest('.call')
  uuid = $('.uuid', call_div).text()
  store.send(
    method: 'hangup',
    uuid: uuid,
    cause: "Agent #{store.agent_name} wants to hang up"
  )
  false

agentWantsCallTransfer = (clickEvent) ->
  call_div = $(clickEvent.target).closest('.call')
  uuid = $('.uuid', call_div).text()
  $('#transfer-cancel').click (cancelEvent) =>
    $('#transfer').hide()
    false;

  $('#transfer').submit (submitEvent) =>
    store.send(
      method: 'transfer',
      uuid: uuid,
      dest: $('#transfer-dest').val(),
    )
    store.calls[uuid].talkingEnd()
    $('#transfer').hide()
    false
  $('#transfer').show()
  false

agentWantsOriginate = (clickEvent) ->
  $('#originate').show()
  $('#originate-dest').focus()
  false

agentOriginates = (submitEvent) ->
  store.send(
    method: 'originate',
    dest: $('#originate-dest').val(),
    agent: store.agent_name,
  )
  $('#originate').hide()
  false

agentCancelsOriginate = (clickEvent) ->
  $('#originate').hide()
  false

agentWantsDTMF = (clickEvent) ->
  call_div = $(clickEvent.target).closest('.call')

  $('.dtmf-form', call_div).toggle ->
    $('.dtmf-input', call_div).focus()
  false

agentWantsToLogout = (clickEvent) ->
  window.location.pathname = "/accounts/logout"

setupWs = ->
  store.ws = new WebSocket(store.server)

  store.ws.onerror = onError
  store.ws.onclose = onClose
  store.ws.onopen = onOpen
  store.ws.onmessage = onMessage

$ ->
  store.server = $('#server').text()
  store.server = "ws://" + location.hostname + ":8080/websocket" if store.server == ''
  store.agent_name = $('#agent_name').text()
  store.agent_ext = $('#agent_ext').text()
  store.call_template = $('#call-template').detach()

  $('#disposition').hide()
  $('#transfer').hide()
  $('#originate').hide()

  $(document).keydown (event) ->
    keyCode = event.keyCode
    bubble = true
    $('#disposition button').each (i, button) ->
      jbutton = $(button)
      keyName = jbutton.attr('accesskey')
      buttonKeyCode = keyCodes[keyName]
      if keyCode == buttonKeyCode
        event.stopPropagation?()
        event.preventDefault?()
        bubble = false
        jbutton.click()
    return bubble

  $('.change-status').live 'click', agentWantsStatusChange
  $('.change-state').live 'click', agentWantsStateChange
  $('.call .hangup').live 'click', agentWantsCallHangup
  $('.call .transfer').live 'click', agentWantsCallTransfer
  $('.call .dtmf').live 'click', agentWantsDTMF
  $('.callme').click agentWantsToBeCalled
  $('.logout').click agentWantsToLogout

  $('.originate').click agentWantsOriginate
  $('#originate').submit agentOriginates
  $('#originate-cancel').click agentCancelsOriginate

  setTimeout ->
    $(window).resize (event) ->
      localStorage.setItem 'agent.bar.width', top.outerWidth
      localStorage.setItem 'agent.bar.height', top.outerHeight
      return true
  , 100

  [width, height] = [localStorage.getItem('agent.bar.width'), localStorage.getItem('agent.bar.height')]
  top.resizeTo(width, height) if width && height

  setupWs()
