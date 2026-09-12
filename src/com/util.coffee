String::lpad = (padString, length) ->
    str = this
    while str.length < length
        str = padString + str
    return str

String::rpad = (padString, length) ->
    if @length < length
        return @ + padString.repeat(length-@length)
    else return @

String::bin = () -> parseInt(@,2)
String::oct = () -> parseInt(@,8)
String::dec = () -> parseInt(@,10)
String::hex = () -> parseInt(@,16)


String::asBin = (l=16) ->
  s=("0000000000000000"+@dec().toString(2))
  return s.slice(s.length-l,s.length)
String::asOct = () -> @dec().toString(8)
String::asHex = (l=4) ->
  s=("00000000"+@dec().toString(16))
  return s.slice(s.length-l,s.length)


Number::bin = () -> String(@).bin()
Number::oct = () -> String(@).oct()
Number::dec = () -> String(@).dec()
Number::hex = () -> String(@).hex()

Number::asBin = (l=16) -> String(@).asBin(l)
Number::asOct = () -> String(@).asOct()
Number::asHex = (l=4) -> String(@).asHex(l)