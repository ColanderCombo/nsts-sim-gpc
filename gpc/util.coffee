import '../com/util'

export class PackedBits
    constructor: (@descStr) ->
        if @descStr
            @desc = @makeDesc(@descStr)

    bin: (s) -> parseInt(s,2)

    makeDesc: (s) ->
        @bitLen = s.length
        desc = {}
        # Get all the unique fields:
        fields = s.replace(/(.)\1+/g, "$1").replace(/[01]/g,'')

        # / indicates fullword instruction
        if fields.match('/')
            # RS / SI / RI
            desc.len = 2
            switch fields.split('/')[1]
                when 'I'
                    if fields.match('d')
                        desc.type = 'SI'
                    else
                        desc.type = 'RI'
                when 'X'
                    desc.type = 'RS'
        else
            # halfword; RR / SRS
            desc.len = 1
            if fields.match('d')
                desc.type = 'SRS'
            else
                desc.type = 'RR'

        desc.mask = @getMask(s)
        desc.maskedVal = @getMaskedDescVal(s)
        desc.f = @makeAllFieldDescs(s)

        desc.origLen = desc.len

        return desc

    getMask: (desc) ->
        w1 = desc.split('/')[0]
        mask = w1.replace(/[01]/g,'1').replace(/[a-z_]/g,'0')
        return mask.bin()

    getMaskedDescVal: (desc) ->
        w1 = desc.split('/')[0]
        masked = w1.replace(/[a-z_]/g,'0')
        return masked.bin()

    makeFieldDesc: (s,fname) ->
        {
            f:fname
            mask: @getFieldMask(s,fname)
            shift: @getFieldShft(s,fname)
            bitlen: @getFieldBitlen(s,fname)
        }

    makeAllFieldDescs: (s) ->
        ss = s.split('/')
        fields = ss[0].replace(/(.)\1+/g, "$1").replace(/[01]/g,'')

        fd = {}
        for f in fields
            fd[f] = @makeFieldDesc(ss[0],f)
        return fd

    getFieldDesc: (desc,f) ->
        return desc.replace(///[^#{f}]///g,'0').replace(///[#{f}]///g,'1')

    getLen: (desc) ->
        return desc.split('/').length

    getFieldMask: (desc,fld) -> parseInt(@getFieldDesc(desc,fld),2)
    getFieldShft: (desc,fld) ->
        d = @getFieldDesc(desc,fld)
        shift = (d.length - d.lastIndexOf('1')) - 1
        return shift
    
    getFieldBitlen: (desc,fld) ->
            m = @getFieldDesc(desc,fld).match(/1/g)
            if m
                return m.length
            else
                return 0

    getField: (data,field) ->
        (data & field.mask) >>> field.shift

    fld: (fd,v) ->
        if fd
            (v << fd.shift) & fd.mask
        else
            0

    setFld: (t,fd,v) ->
        tv = t & ((Math.pow(2,@bitLen)-1) ^ fd.mask)
        tv = tv | (v << fd.shift) & fd.mask
        return tv
