    ops: {
        A:      {d:'00000xxxddddddbb', e:(t,v)-> }
        AR:     {d:'00000xxx11100yyy', e:(t,v)-> }
        XUL:    {d:'00000xxx11101yyy', e:(t,v)->}
        AST:    {d:'00000xxx11111abb/X', e:(t,v)->}

        S:      {d:'00001xxxddddddbb', e:(t,v)->}
        SR:     {d:'00001xxx11100yyy', e:(t,v)->}
        CBL:    {d:'00001xxx11101yyy', e:(t,v)->}
        SST:    {d:'00001xxx11111abb/X', e:(t,v)->}

        C:      {d:'00010xxxddddddbb', e:(t,v)->}
        CR:     {d:'00010xxx11100yyy', e:(t,v)->}
        DEDR:   {d:'00010xxx11101yyy', e:(t,v)->}
        DED:    {d:'00010xxx11111abb/X', e:(t,v)->}

        L:      {d:'00011xxxddddddbb', e:(t,v)->}
        LR:     {d:'00011xxx11100yyy', e:(t,v)->}

        N:      {d:'00100xxxddddddbb', e:(t,v)->}
        NR:     {d:'00100xxx11100yyy', e:(t,v)->}
        LFXR:   {d:'00100xxx11101yyy',e:(t,v)->}
        NST:    {d:'00100xxx11111abb/X', e:(t,v)->}

        O:      {d:'00101xxxddddddbb', e:(t,v)->}
        OR:     {d:'00101xxx11100yyy', e:(t,v)->}
        LFLR:   {d:'00101xxx11101yyy',e:(t,v)->}
        OST:    {d:'00101xxx11111abb/X', e:(t,v)->}

        ST:     {d:'00110xxxddddddbb', e:(t,v)->}
        MEDR:   {d:'00110xxx11101yyy', e:(t,v)->}
        MED:    {d:'00110xxx11111abb/X', e:(t,v)->}

        STE:    {d:'00111xxxddddddbb', e:(t,v)->}
        CVFX:   {d:'00111xxx11100yyy', e:(t,v)->}
        CVFL:   {d:'00111xxx11101yyy', e:(t,v)->}
        STED:   {d:'00111xxx11111abb/X', e:(t,v)->}

        M:      {d:'01000xxxddddddbb', e:(t,v)->}
        MR:     {d:'01000xxx11100yyy', e:(t,v)->}

        D:      {d:'01001xxxddddddbb', e:(t,v)->}
        DR:     {d:'01001xxx11100yyy', e:(t,v)->}
        CER:    {d:'01001xxx11101yyy', e:(t,v)->}
        CE:     {d:'01001xxx11111abb/X', e:(t,v)->}

        AE:     {d:'01010xxxddddddbb', e:(t,v)->}
        AER:    {d:'01010xxx11100yyy', e:(t,v)->}
        AEDR:   {d:'01010xxx11101yyy', e:(t,v)->}
        AED:    {d:'01010xxx11111abb/X', e:(t,v)->}

        SE:     {d:'01011xxxddddddbb', e:(t,v)->}
        SER:    {d:'01011xxx11100yyy', e:(t,v)->}
        SEDR:   {d:'01011xxx11101yyy', e:(t,v)->}
        SED:    {d:'01011xxx11111abb/X', e:(t,v)->}

        ME:     {d:'01100xxxddddddbb', e:(t,v)->}
        MER:    {d:'01100xxx11100yyy', e:(t,v)->}
        MVS :   {d:'01100xxx11111abb/X', e:(t,v)->}

        DE:     {d:'01101xxxddddddbb', e:(t,v)->}
        DER:    {d:'01101xxx11100yyy', e:(t,v)->}
        MVH:    {d:'01101xxx11101yyy',e:(t,v)->}

        X:      {d:'01110xxxddddddbb', e:(t,v)->}
        XR:     {d:'01110xxx11100yyy', e:(t,v)->}
        XST:    {d:'01110xxx11111abb/X', e:(t,v)->}
 
        LE:     {d:'01111xxxddddddbb', e:(t,v)->}
        LER:    {d:'01111xxx11100yyy', e:(t,v)->}
        LECR:   {d:'01111xxx11101yyy',e:(t,v)->}
        LED:    {d:'01111xxx11111abb/X', e:(t,v)->}       

        AH:     {d:'10000xxxddddddbb', e:(t,v)->}
        IHL:    {d:'10000xxx11111abb/X', e:(t,v)->}

        SH:     {d:'10001xxxddddddbb', e:(t,v)->}
        LFLI:   {d:'10001xxx1110yyyy',e:(t,v)->}
        SSM:    {d:'1000100011111abb/X',e:(t,v)->}

        SRET:   {d:'10010xxx11101yyy',e:(t,v)->}
        CH:     {d:'10010xxxddddddbb', e:(t,v)->}

        MIH:    {d:'10011xxx11111abb/X', e:(t,v)->}
        LH:     {d:'10011xxxddddddbb', e:(t,v)->}

        AHI:    {d:'1011000011100yyy/I', e:(t,v)->}
        CIST:   {d:'10110101ddddddbb/I', e:(t,v)->}
        CHI:    {d:'1011010111100yyy/I', e:(t,v)->}

        LFXI:   {d:'10111xxx1110yyyy', e:(t,v)->}

        SHW:    {d:'10100010ddddddbb', e:(t,v)->}
        TH:     {d:'10100011ddddddbb', e:(t,v)->}
        ZH:     {d:'10100001ddddddbb', e:(t,v)->}
        ZHe:    {d:'10100001111100bb/D', e:(t,v)->}
        ZHi:    {d:'10100001111101bb/I', e:(t,v)->}
        TD:     {d:'10100000ddddddbb', e:(t,v)->}

        MH:     {d:'10101xxxddddddbb', e:(t,v)->}

        MSTH:   {d:'10110000ddddddbb/D', e:(t,v)->}
        ZB:     {d:'10110001ddddddbb/I', e:(t,v)->}
        ZRB:    {d:'1011000111100yyy/I', e:(t,v)->}
        OHI:    {d:'1011001011100yyy/I', e:(t,v)->}
        SB:     {d:'10110010ddddddbb/I', e:(t,v)->}
        TB:     {d:'10110011ddddddbb/I', e:(t,v)->}
        TRB:    {d:'1011001111100yyy/R', e:(t,v)->}

        XHI:    {d:'1011010011100yyy/I', e:(t,v)->}
        XIST:   {d:'10110100ddddddbb/I', e:(t,v)->}
        NIST:   {d:'10110110ddddddbb/I', e:(t,v)->}
        NHI:    {d:'1011011011100yyy/I', e:(t,v)->}
        TSB:    {d:'10110111ddddddbb/I',e:(t,v)->}
        MHI:    {d:'1011011111100yyy/I', e:(t,v)->}

        SUM:    {d:'10011xxx11101yyy', e:(t,v)->}
        STH:    {d:'10111xxxddddddbb', e:(t,v)->}
        TS:     {d:'1011100011111abb/X',e:(t,v)->}

        BCR:    {d:'11000xxx11100yyy', e:(t,v)->}
        BC:     {d:'11000xxx11100abb/X', e:(t,v)->}
        BCRE:   {d:'11000xxx11101yyy', e:(t,v)->}
        _DETECT:{d:'11000000111110bb/0',e:(t,v)->}
        
        BVCR:   {d:'11001xxx11100yyy', e:(t,v)->}
        BVC:    {d:'11001xxx11110abb/X', e:(t,v)->}
        STM:    {d:'1100100011111abb/X', e:(t,v)->}
        SPM:    {d:'1100100011101yyy',e:(t,v)->}
        SVC:    {d:'1100100111111abb/X',e:(t,v)->}
        LM :    {d:'1100110011111abb/X', e:(t,v)->}
        LPS:    {d:'1100110111111abb/X', e:(t,v)->}

        BCTR:   {d:'11010xxx11100yyy', e:(t,v)->}
        BCT:    {d:'11010xxx11110abb/X', e:(t,v)->}
        SCAL:   {d:'11010xxx11111abb/X',e:(t,v)->}

        PC:     {d:'11011xxx11101yyy', e:(t,v)->}

        BCF:    {d:'11011xxxdddddd00', e:(t,v)->}
        BVCF:   {d:'11011xxxdddddd01', e:(t,v)->}
        BCB:    {d:'11011xxxdddddd10', e:(t,v)->}
        BCTB:   {d:'11011xxxdddddd11', e:(t,v)->}
        ICR:    {d:'11011xxx11100yyy',e:(t,v)->}
        BIX:    {d:'11011xxx11110abb/X', e:(t,v)->}

        IAL:    {d:'11100xxxddddddbb', e:(t,v)->}
        BALR:   {d:'11100xxx11100yyy', e:(t,v)->}
        NCT:    {d:'11100xxx11101yyy', e:(t,v)->}
        BAL:    {d:'11100xxx11110abb/X', e:(t,v)->}
        IAL:    {d:'11100xxx11111abb/X', e:(t,v)->}

        LA:     {d:'11101xxxddddddbb', e:(t,v)->}
        LCR:    {d:'11101xxx11101yyy', e:(t,v)->}
        ISPB:   {d:'11101xxx11111abb/X',e:(t,v)->}

        SLL:    {d:'11110xxxdddddd00', e:(t,v)->}
        SRA:    {d:'11110xxxdddddd01', e:(t,v)->}
        SRL:    {d:'11110xxxdddddd10', e:(t,v)->}
        SRR:    {d:'11110xxxdddddd11', e:(t,v)->}

        SLDL:   {d:'11111xxxdddddd00', e:(t,v)->}
        SRDA:   {d:'11111xxxdddddd01', e:(t,v)->}
        SRDL:   {d:'11111xxxdddddd10', e:(t,v)->}
        SRDR:   {d:'11111xxxdddddd11', e:(t,v)->}
    }