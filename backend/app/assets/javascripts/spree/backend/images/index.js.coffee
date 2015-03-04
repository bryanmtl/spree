$ ->
  ($ '#new_image_link').click (event) ->
    event.preventDefault()

    ($ '.no-objects-found').hide()

    ($ this).hide()
    $.ajax
      type: 'GET'
      url: @href
      headers: { "X-Spree-Token": Spree.api_key }
      data: (
        authenticity_token: AUTH_TOKEN
      )
      success: (r) ->
        ($ '#images').html r
