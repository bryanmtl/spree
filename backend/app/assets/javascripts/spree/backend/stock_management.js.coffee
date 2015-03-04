jQuery ->
  $('.stock_item_backorderable').on 'click', ->
    $(@).parent('form').submit()
  $('.toggle_stock_item_backorderable').on 'submit', ->
    $.ajax
      type: @method
      url: @action
      headers: { "X-Spree-Token": Spree.api_key }
      data: $(@).serialize()
    false
