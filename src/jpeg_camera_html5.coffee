if navigator.mediaDevices && navigator.mediaDevices.getUserMedia
  navigator.getUserMedia = (constraints, success, failure) ->
    promise = navigator.mediaDevices.getUserMedia constraints
    promise.then(success).catch(failure)
else
  navigator.getUserMedia ||=
    navigator.webkitGetUserMedia ||
    navigator.mozGetUserMedia ||
    navigator.msGetUserMedia

window.AudioContext ||=
  window.webkitAudioContext

window.$ ||= {}
window.$.i18n ||= () ->
  return ""

# @private
check_canvas_to_blob = ->
  canvas = document.createElement "canvas"
  if canvas.getContext && !canvas.toBlob
    throw "JpegCamera: Canvas-to-Blob is not loaded"

if navigator.getUserMedia
  check_canvas_to_blob()

  vorbis_audio = "audio/ogg; codecs=vorbis"
  mpeg_audio = "audio/mpeg; "

  # @private
  can_play = (type) ->
    elem = document.createElement "video"
    !!(elem.canPlayType && elem.canPlayType(type).replace(/no/, ''))

  # JpegCamera implementation that uses _getUserMedia_ to capture snapshots,
  # _canvas_element_ to display them, _XHR_ to upload them to the server and
  # optionally _Web_Audio_API_ to play shutter sound.
  #
  # @private
  class JpegCameraHtml5 extends JpegCamera
    _engine_init: ->
      @_debug "Using HTML5 engine"

      vertical_padding = Math.floor @view_height * 0.2
      horizontal_padding = Math.floor @view_width * 0.2

      @message = document.createElement "div"
      @message.class = "message"
      @message.style.width = "100%"
      @message.style.height = "100%"
      JpegCamera._add_prefixed_style @message, "boxSizing", "border-box"
      @message.style.overflow = "hidden"
      @message.style.textAlign = "center"
      @message.style.paddingTop = "#{vertical_padding}px"
      @message.style.paddingBottom = "#{vertical_padding}px"
      @message.style.paddingLeft = "#{horizontal_padding}px"
      @message.style.paddingRight = "#{horizontal_padding}px"
      @message.style.position = "absolute"
      @message.style.zIndex = 3
      @message.innerHTML = $.i18n "PleaseAgreeCameraAccess"

      @container.appendChild @message

      @video_container = document.createElement "div"
      @video_container.style.width = "#{@view_width}px"
      @video_container.style.height = "#{@view_height}px"
      @video_container.style.overflow = "hidden"
      @video_container.style.position = "absolute"
      @video_container.style.zIndex = 1

      @container.appendChild @video_container

      @video = document.createElement 'video'
      @video.autoplay = true
      JpegCamera._add_prefixed_style @video, "transform", "scalex(-1.0)"

      if window.AudioContext
        if can_play vorbis_audio
          @_load_shutter_sound @options.shutter_ogg_url
        else if can_play mpeg_audio
          @_load_shutter_sound @options.shutter_mp3_url

      get_user_media_options =
        video:
          facingMode:
            ideal:
              "environment"
          optional: [
            {minWidth: 1280},
            {minWidth: 640},
            {minWidth: 480},
            {minWidth: 360}
          ]

      that = this
      success =
        (stream) ->
          that._remove_message()
          that.stream = stream

          if window.URL
            try 
              that.video.srcObject = stream
            catch
              that.video.src = URL.createObjectURL stream
          else
            that.video.src = stream

          that._block_element_access()

          that._wait_for_video_ready()
      failure =
        # XXX Receives NavigatorUserMediaError object and searches for
        # constant name matching error.code. With the current specification
        # version this will always evaluate to
        # `that._got_error("PERMISSION_DENIED")`.
        (error) ->
          console.log "Failed to activate camera", error
          if get_user_media_options.video.facingMode
            delete get_user_media_options.video.facingMode
            navigator.getUserMedia get_user_media_options, success, failure
          else if get_user_media_options.video.deviceId
            delete get_user_media_options.video.deviceId
            navigator.getUserMedia get_user_media_options, success, failure
          else 
            that.message.innerHTML =
              "<span style=\"color: red;\">" +
                $.i18n("CameraAccessDenied") +
              "</span><br><br>" +
              $.i18n("ClickCameraIconToAllowIt")

            code = error.code
            for key, value of error
              continue if key == "code"
              that._got_error key
              return
            that._got_error "UNKNOWN ERROR"

      activate = () ->
        # XXX In an older spec first parameter was a string
        try
          navigator.getUserMedia get_user_media_options, success, failure
        catch error
          navigator.getUserMedia "video", success, failure

      gotDevices = (devs) ->
        for key, value of devs
          continue if value.kind != "videoinput"
          console.log value
          if value.facingMode == "environment" || value.label.indexOf("facing back") >= 0
            console.log "Using device: " + value.deviceId
            get_user_media_options.video.deviceId = value.deviceId
        if get_user_media_options.video.deviceId
          delete get_user_media_options.video.facingMode
          delete get_user_media_options.video.optional
        that._engine_stop()
        activate()

      enumDevices = (stream) ->
        that.stream = stream
        navigator.mediaDevices.enumerateDevices().then(gotDevices)

      if @options.front
        @_debug "Using front camera"
        delete get_user_media_options.video.facingMode
        activate()
      else
        @_debug "Using rear camera"
        isAndroid = (/Android/i).test(navigator.userAgent);
        if isAndroid && navigator.mediaDevices && navigator.mediaDevices.getUserMedia && navigator.mediaDevices.enumerateDevices
          navigator.mediaDevices.getUserMedia({ video: true }).then(enumDevices)
        else
          activate()

    _engine_play_shutter_sound: ->
      return unless @shutter_buffer

      source = @audio_context.createBufferSource()
      source.buffer = @shutter_buffer
      source.connect @audio_context.destination
      source.start 0

    _engine_capture: (snapshot, mirror, quality, scale) ->
      crop = @_get_capture_crop()

      canvas = document.createElement "canvas"
      canvas.width = Math.round crop.width * scale
      canvas.height = Math.round crop.height * scale

      context = canvas.getContext "2d"
      context.drawImage @video,
        crop.x_offset, crop.y_offset,
        crop.width, crop.height,
        0, 0,
        Math.round(crop.width * scale), Math.round(crop.height * scale)

      snapshot._canvas = canvas
      snapshot._mirror = mirror
      snapshot._quality = quality

    _engine_stop: () -> 
      if !this.stream 
        console.log 'Camera stream not started'
        return
      try
        if this.stream['getTracks']
          tracks = this.stream.getTracks()
          for i of tracks 
            tracks[i].stop()

        if this.stream.stop
          this.stream.stop()
      catch
        console.log 'Failed to stop camera stream'

    _engine_display: (snapshot) ->
      if @displayed_canvas
        @container.removeChild @displayed_canvas

      @displayed_canvas = snapshot._canvas
      @displayed_canvas.style.width = "#{@view_width}px"
      @displayed_canvas.style.height = "#{@view_height}px"
      @displayed_canvas.style.top = 0
      @displayed_canvas.style.left = 0
      @displayed_canvas.style.position = "absolute"
      @displayed_canvas.style.zIndex = 2
      JpegCamera._add_prefixed_style @displayed_canvas,
        "transform", "scalex(-1.0)"

      @container.appendChild @displayed_canvas

    _engine_get_canvas: (snapshot) ->
      canvas = document.createElement "canvas"
      canvas.width = snapshot._canvas.width
      canvas.height = snapshot._canvas.height
      context = canvas.getContext "2d"
      context.drawImage snapshot._canvas, 0, 0
      canvas

    _engine_get_image_data: (snapshot) ->
      canvas = snapshot._canvas
      context = canvas.getContext "2d"
      context.getImageData 0, 0, canvas.width, canvas.height

    _engine_get_blob: (snapshot, mime, mirror, quality, callback) ->
      if mirror
        canvas = document.createElement "canvas"
        canvas.width = snapshot._canvas.width
        canvas.height = snapshot._canvas.height

        context = canvas.getContext "2d"
        context.setTransform 1, 0, 0, 1, 0, 0 # reset transformation matrix
        context.translate canvas.width, 0
        context.scale -1, 1
        context.drawImage snapshot._canvas, 0, 0
      else
        canvas = snapshot._canvas

      canvas.toBlob ((blob) -> callback blob), mime, quality

    _engine_discard: (snapshot) ->
      if snapshot._xhr
        snapshot._xhr.abort()
      delete snapshot._xhr
      delete snapshot._canvas

    _engine_show_stream: ->
      if @displayed_canvas
        @container.removeChild @displayed_canvas
        @displayed_canvas = null

      @video_container.style.display = "block"

    _engine_upload: (snapshot, api_url, csrf_token, timeout) ->
      @_debug "Uploading the file"

      snapshot.get_blob (blob) ->
          handler = (event) ->
            delete snapshot._xhr

            snapshot._status = event.target.status
            snapshot._response = event.target.responseText

            if snapshot._status >= 200 && snapshot._status < 300
              snapshot._upload_done()
            else
              snapshot._error_message =
                event.target.statusText || "Unknown error"
              snapshot._upload_fail()
          xhr = new XMLHttpRequest()
          xhr.open 'POST', api_url
          xhr.timeout = timeout
          xhr.setRequestHeader "X-CSRF-Token", csrf_token if csrf_token
          xhr.onload = handler
          xhr.onerror = handler
          xhr.onabort = handler
          xhr.send blob

          snapshot._xhr = xhr
        , "image/jpeg"

    _remove_message: ->
      @message.style.display = "none"

    _load_shutter_sound: (url) ->
      return if @audio_context

      @audio_context = new AudioContext()

      request = new XMLHttpRequest()
      request.open 'GET', url, true
      request.responseType = 'arraybuffer'

      that = this
      request.onload = ->
        that.audio_context.decodeAudioData request.response, (buffer) ->
          that.shutter_buffer = buffer
      request.send()

    _wait_for_video_ready: ->
      video_width = parseInt @video.videoWidth
      video_height = parseInt @video.videoHeight

      if video_width > 0 && video_height > 0
        @video_container.appendChild @video

        @video_width = video_width
        @video_height = video_height

        crop = @_get_video_crop()

        @video.style.position = "relative"
        @video.style.width = "#{crop.width}px"
        @video.style.height = "#{crop.height}px"
        @video.style.left = "#{crop.x_offset}px"
        @video.style.top = "#{crop.y_offset}px"

        @_prepared(@video_width, @video_height)
      else if @_status_checks_count > 100
        @_got_error "Camera failed to initialize in 10 seconds"
      else
        @_status_checks_count++
        that = this
        setTimeout (-> that._wait_for_video_ready()), 100

    _status_checks_count: 0

    _get_video_crop: ->
      video_ratio = @video_width / @video_height
      view_ratio = @view_width / @view_height

      if video_ratio >= view_ratio
        # fill height, crop width
        @_debug "Filling height"
        video_scale = @view_height / @video_height
        scaled_video_width = Math.round @video_width * video_scale

        width: scaled_video_width
        height: @view_height
        x_offset: -Math.floor((scaled_video_width - @view_width) / 2.0)
        y_offset: 0
      else
        # fill width, crop height
        @_debug "Filling width"
        video_scale = @view_width / @video_width
        scaled_video_height = Math.round @video_height * video_scale

        width: @view_width
        height: scaled_video_height
        x_offset: 0
        y_offset: -Math.floor((scaled_video_height - @view_height) / 2.0)

    _get_capture_crop: ->
      video_ratio = @video_width / @video_height
      view_ratio = @view_width / @view_height

      if video_ratio >= view_ratio
        # take full height, crop width
        snapshot_width = Math.round @video_height * view_ratio

        width: snapshot_width
        height: @video_height
        x_offset: Math.floor((@video_width - snapshot_width) / 2.0)
        y_offset: 0
      else
        # take full width, crop height
        snapshot_height = Math.round @video_width / view_ratio

        width: @video_width
        height: snapshot_height
        x_offset: 0
        y_offset: Math.floor((@video_height - snapshot_height) / 2.0)

  video_width: null
  video_height: null

  window.JpegCamera = JpegCameraHtml5
