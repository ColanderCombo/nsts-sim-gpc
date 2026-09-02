fs = window.fs
OVERLAY_DIR = 'data/overlay_images/'   # reference-overlay image library
import * as THREE from 'three';
import { EffectComposer } from 'three/examples/jsm/postprocessing/EffectComposer.js';
import { RenderPass } from 'three/examples/jsm/postprocessing/RenderPass.js';
import 'path-data-polyfill'
import * as ss from 'svg-segmentize'

deuFontSvg = require('data/deu_font.svg')
medsFontSvg = require('data/meds_font.svg')

import {makeSDFLineGeometry, makeSDFLineMaterial} from 'meds/shader/sdfLine'

Empty = Object.freeze( [] )

rad2deg = (v) -> v * (180 / Math.PI)
deg2rad = (v) -> v * (Math.PI / 180)

$ = require('jquery')

class CharGen
  constructor: (@suffix,@CONFIG) ->
    @chars = { ' ': []}
    @loadCharSVG()

  loadCharSVG: () ->
    @cc = {
      meds: medsFontSvg,
      deu: deuFontSvg
    }
    @chars = {
      # meds: await fetch(medsFontSvg),
      # deu: await fetch(deuFontSvg),
      meds: medsFontSvg,
      deu: deuFontSvg
    }
    svgDoc = @chars[@suffix]
    for desc in $("*",svgDoc)
      @makeGlyphMesh(desc)
    console.log(@)

  makeGlyphMesh2: (svgDesc) ->
    # Using svg-sgmentize:
    # console.log(svgDesc)
    segs = ss.default(svgDesc, {output: 'data', resolution:{path:20}})
    # Get the character code from the id:
    id = $(svgDesc).prop('id')
    if id[0] == 'c' 
      # Illustrator prepends a '_' if the layer starts with a number
      id = id[1..]
    chr = String.fromCharCode(parseInt(id)+33)
    # console.log("CHAR", id, chr)
    @chars[chr] = segs


  makeGlyphMesh: (svgDesc) -> 
    id = $(svgDesc).prop('id')
    # console.log("CHAR", id)
    if id[0] == 'c' 
      # Illustrator prepends a '_' if the layer starts with a number
      id = id[1..]
    chr = String.fromCharCode(parseInt(id)+33)

    strokes = []
    for stroke in $("*", svgDesc)    
      scl = (xc,xoff,s) -> 0.9*(xoff+xc/s)
      # xy = (xc,yc) -> [scl(xc,-.15,55), scl(yc,-.65,80)]
      # xy = (xc,yc) -> [0.75+scl(xc,0,512/53), scl(yc,0,512/35)]
      xy = (xc,yc) -> [0.95+scl(xc,0,512/43), 0.10+scl(yc,0,512/30)]


      # segs = svgSegs(stroke, {output: 'data', resolution:{path:20}})
      # console.log(segs)
      # for seg in segs
      #   coords = []
      #   coords.push xy(seg[0], seg[1])
      #   coords.push xy(seg[2], seg[3])
      #   strokes.push coords


      if $(stroke).prop('tagName') == 'line'
        p1 = xy(parseFloat($(stroke).attr('x1')),
                parseFloat($(stroke).attr('y1')))
        p2 = xy(parseFloat($(stroke).attr('x2')),
                parseFloat($(stroke).attr('y2')))
        strokes.push [p1,p2]
        # console.log("L",strokes.length, strokes)
      else if $(stroke).prop('tagName') == 'polyline'
        points = $(stroke).prop('points')
        coords = []
        for pt in points
          coords.push xy(pt.x, pt.y)
        strokes.push coords
      else if $(stroke).prop('tagName') == 'polygon'
        points = $(stroke).prop('points')
        coords = []
        for pt in points
          coords.push xy(pt.x, pt.y)
        coords.push xy(points[0].x, points[0].y)
        strokes.push coords
      else if $(stroke).prop('tagName') == 'path'
        pp = document.createElementNS("http://www.w3.org/2000/svg", "path")
        sd = $(stroke).attr('d')
        pp.setAttribute("d", $(stroke).attr('d'))
        data = pp.getPathData()
        lastPt = [0,0]
        coords = []
        for pt in data
          switch pt.type
            when 'M' # Move to (x,y)
              lastPt = pt.values
              coords.push xy(pt.values[0], pt.values[1])
            when 'm' # relative move to (x,y)
              newPt = [lastPt[0] + pt.values[0], lastPt[1]+pt.values[1]]
              # coords.push xy(pt.values[0], pt.values[1])
              lastPt = newPt
            when 'V' # Vertical Line to (y)
              lastPt[1] = pt.values[0]
              coords.push xy(lastPt[0], pt.values[0])
            when 'v' # Vertical Line to (y)
              newPt = [lastPt[0], lastPt[1] + pt.values[0]]
              coords.push xy(newPt[0], newPt[1])
              lastPt = newPt
            when 'H' # Horizontal Line to (x)
              lastPt[0] = pt.values[0]
              coords.push xy(pt.values[0], lastPt[1])
            when 'h' # Horizontal Line to (x)
              newPt = [lastPt[0] + pt.values[0], lastPt[1]]
              coords.push xy(newPt[0], newPt[1])
              lastPt = newPt
            when 'L' # Line to (x,y)
              lastPt = pt.values
              coords.push xy(pt.values[0], pt.values[1])
            when 'l'
              newPt = [lastPt[0] + pt.values[0], lastPt[1]+pt.values[1]]
              coords.push xy(newPt[0], newPt[1])
              lastPt = newPt
            when 'Z'
              # coords.push xy(data[0].values[0], data[0].values[1])
              coords.push coords[0]
        strokes.push coords
        # console.log("P",strokes.length, strokes)
        #strokes.push Line(coords,{distances:true})

    # console.log(chr)
    @chars[chr] = strokes

  drawGlyph: (mdu,dl,glyphChar,x,y,c,scaleFactor=1.0,scalex=1.0,rot=0,centered=false,clip=null) ->
    # console.log("#{glyphChar} #{mat}")
    if not @chars.hasOwnProperty(glyphChar) then return []
    strokes = @chars[glyphChar]

    gcx = 0 ; gcy = 0
    if rot or centered
      # glyph bounding-box centre (used to spin and/or centre about the glyph)
      minx = miny = 1e9 ; maxx = maxy = -1e9
      for stroke in strokes
        for p in stroke
          minx = Math.min(minx,p[0]) ; maxx = Math.max(maxx,p[0])
          miny = Math.min(miny,p[1]) ; maxy = Math.max(maxy,p[1])
      gcx = (minx+maxx)/2 ; gcy = (miny+maxy)/2

    if rot
      # rotate in pixel-proportional space (cols and rows have different px
      # scales) so the glyph stays rigid instead of shearing/squashing
      cs = Math.cos(rot) ; sn = Math.sin(rot) ; AR = 18.789/13.783   # pxRow/pxCol
      strokes = ( ([gcx+(p[0]-gcx)*cs-(p[1]-gcy)*AR*sn, gcy+(p[0]-gcx)*sn/AR+(p[1]-gcy)*cs] for p in stroke) for stroke in strokes )

    geoms = []
    for stroke in strokes
      buffer = mdu.line(stroke,c,1.0,clip)
      if centered
        # put the glyph's centre on (x,y) instead of the default corner origin
        buffer.position.set(x - scaleFactor*scalex*gcx, y - scaleFactor*gcy, 0)
      else
        buffer.position.set(x-1, y, 0)
      buffer.scale.set(scaleFactor*scalex, scaleFactor, 1)
      buffer.updateMatrix()
      geoms.push buffer
    return geoms

export class VectorDisplay
  makeConstants: () ->
    @c2h = {
      black: 0x101336,
      # black: 0x080b25,
      #black: 0x040518,
      #black: 0x000106,
      # --> Actual measured
      # darkGray: 0x5f6199,
      # lightGray: 0xffe2d5,
      # white: 0xfffbd2,
      # <-- Actual measured
      darkGray: 0x777780,
      lightGray: 0x9999a0,
      white: 0xffffff,
      orange: 0xff8c06,
      red: 0xff232b,
      yellow: 0xfff600,
      cyan: 0x2dfada,
      magenta: 0xff43de,
      lightGreen: 0x48f500,
      green: 0x48f500,
      darkGreen: 0x368524,
      blue: 0x003ce0,
      pink: 0xfff9d4,
      brown: 0xff7049
    }
    console.log("makeConst")
    # SDF stroke settings, in display pixels: full stroke width and the edge
    # feather half-width. Shared uniform refs (resolution/pxRatio) let render()
    # update every line material at once when the framebuffer size changes.
    @LINE_PX = @CONFIG.lineWidthPx ? 2.2
    @LINE_AA = @CONFIG.lineSoftness ? 1.1
    @resolutionU = { value: new THREE.Vector2(720, 720) }
    @pxRatioU = { value: 1.0 }
    @sdfOpt = (o) => Object.assign({resolution: @resolutionU, pxRatio: @pxRatioU, widthPx: @LINE_PX, aaPx: @LINE_AA}, o)
    @mats = [{},{}] # normal, blink
    @dashMats = {} # dashed line materials (DEU FEAT lineDash)
    for c,v of @c2h
      @mats[0][v] = makeSDFLineMaterial(THREE, @sdfOpt({color: v}))
      @mats[1][v] = makeSDFLineMaterial(THREE, @sdfOpt({color: v}))
      @dashMats[v] = makeSDFLineMaterial(THREE, @sdfOpt({color: v, dashSize: 1.0, gapSize: 0.35}))
    # Graded-brightness ramps for DEU FEAT intensity (0..max), one per
    # colour.  Fade via opacity (not toward black) so whatever is behind
    # shows through.  One ramp per colour: the DEU's normal intensity is
    # 0.72, so everything below full intensity takes this path.  Green is
    # pre-built, being most of what a display draws; the rest are made on
    # demand in `line`.
    @NINT = 32
    @intMats = {}
    @intMats[@c2h.green] =
      (makeSDFLineMaterial(THREE, @sdfOpt({color: @c2h.green, opacity: i/(@NINT-1)})) \
       for i in [0...@NINT])
      
    

    @NO_CLIP = new THREE.Vector4(0,100, 0,100)

  constructor: (@CONFIG) ->
    @s = ss
    @makeConstants()
    @init()

  CAM_PAD_LEFT = 0.20
  CAM_PAD_RIGHT = 0.20 + 0.242456
  CAM_PAD_TOP = 0.25 - 2
  CAM_PAD_BOTTOM = 0.57 - 2

  CHAR_WIDTH = 53
  CHAR_HEIGHT = 38

  setZoomCamera: (zoom, charX, charY) ->
    # set ortho camera to zoom in on a specific character
    # zoom is 1 for normal size, 2 for double size, etc.
    # charX and charY are the character coordinates to zoom in on
    if zoom == 1
      @resetCamera()
      return

    @camera.left = charX - (CHAR_WIDTH/2)*zoom
    @camera.right = charX + (CHAR_WIDTH/2)*zoom
    @camera.top = charY - (CHAR_HEIGHT/2)*zoom
    @camera.bottom = charY + (CHAR_HEIGHT/2)*zoom
    @camera.updateProjectionMatrix()

  resetCamera: () ->
    @camera.left = 0 + CAM_PAD_LEFT
    @camera.right = CHAR_WIDTH + CAM_PAD_RIGHT
    @camera.top =  0 + CAM_PAD_TOP
    @camera.bottom =  CHAR_HEIGHT + CAM_PAD_BOTTOM
    @camera.updateProjectionMatrix()

  init: () ->
    @dirty = true

    @deuFont = new CharGen('deu',@CONFIG)
    @medsFont = new CharGen('meds',@CONFIG)



    @objNorm = []
    @objBlink = []

    # "Anti-aliasing filters are responsible for converting the 576x576 
    # Video RAM (VRAM) image into the 1152x1152 addressability required
    # by the LCD.  An active display area of 6.71x6.71 in. is achieved 
    # will 1152x1152 pixels resolution and 28 shades of gray per primary
    # color."
    #   ref. THESIS - The Space Shuttle Orbiter's Advenced Display Designs and an Analysis of Its Growth Capabilities (1995)/p.28
    # MDU Envelope: 8in. H x 8.75 in W x 8.75in D
    # Active viewing Area: 6.71in x 6.71in
    # Color dot resolution: 172 dot/in.
    # LCD dot matrix: 1152x1152
    # Pixel arrangement: RGB triad
    # Viewing angles: H +/- 60 deg, V -10deg/+45deg
    # Contrast ratio (<1 fc) 
    #  ERP                  >90:1
    #  H(+/-20):V(0/+20)    >65:1
    #  H(+/-45):V(-10/+30)  >45:1
    #  H(+/-60):V(-10/+45)  >15:1
    #
    # Contrast Ratio (high ambient) >6:1 (all angles)
    # Display leakage               <3.5 fL (all angles)
    # Specular Reflectance          1.00% at 30 deg
    # Diffuse Reflectance           0.06% at 30 deg
    # Luminance Uniformity
    #       Red: 11.5%
    #       Grn: 12.9%
    #       Blu: 16%
    #       Wht: 16%
    #       Blk: 18%
    #
    # Color uniformity  (panel to panel and within panel)
    #     Primaries: <0.015 radius
    #     Secondaries: <0.021 radius
    #     Gray scales: <0.021 radius
    #
    # Chromaticity (u',v')
    #     Red   (0.416,0.522)
    #     Green (0.118,0.544)
    #     Blue  (0.146,0.338)
    #     White (0.215,0.482)
    #     
    # Response time <18ms at 25 deg C
    #


    # Get desired dimensions:
    # DEU actual size: 6.71in x 6.71in
    #                  1152px x 1152px


    #
    @widthPx = @CONFIG.window.width
    @heightPx = @CONFIG.window.height

    # Display coordinate system.  The original vector displays have a
    # logical resolution of 1024x1024.
    #
    # 51x26 (the character grid)
    #   + 0.50 x border
    #   + 0.25 y border
    #   + menu y area
    #
    # @camera = new THREE.OrthographicCamera 0,53,.25,36.25,-1,1
    
    # Normal:
    #### @camera = new THREE.OrthographicCamera 0,53,.25,36.25,-20,20
    # top/bottom +0.374 pans the view ~10px so content sits higher and the menu
    # fits above the bottom clip plane (extent unchanged -> no distortion)
    @camera = new THREE.OrthographicCamera 0+.20,52.242456+.20,.25-2+0.374,38.57-2+0.374,-100,500

# var camera = new THREE.PerspectiveCamera(60, window.innerWidth / window.innerHeight, 1, 10000)
# camera.position.set(500, 0, 0)


    # Debug zoom:
    # @camera = new THREE.OrthographicCamera 0,(53/5),20+.25,20+(36.25/5),-20,20
    # @camera = new THREE.OrthographicCamera 0,(53/20),20+.25,20+(36.25/20),-20,20

    # @camera.position.xyz = new THREE.Vector3(100,0,0)
    @camera.position.z = 0

    @superRatio = @CONFIG.supersample

    @scene = new THREE.Scene()
    @scene.background = new THREE.Color(@c2h.black)   # dark-blue bg on every display (via composer clear)
    @scene.add(new THREE.AmbientLight( 0xffffff ))
    @camera.lookAt @scene.position
    @renderer = new THREE.WebGLRenderer {
                                            canvas: $('#screen')[0]
                                            antialias: true
                                            preserveDrawingBuffer: true
                                        }
    document.body.appendChild(@renderer.domElement)
    @renderer.setSize(@widthPx,@heightPx)
    # --size: render at the config resolution and scale the canvas element
    # down, so stroke weights shrink with it.
    if @CONFIG.window.displayPx
      @renderer.domElement.style.width = "#{@CONFIG.window.displayPx}px"
      @renderer.domElement.style.height = "#{@CONFIG.window.displayPx}px"
    @renderer.setClearColor(@c2h.black)
    @renderer.autoClear = false
    @renderer.localClippingEnabled = true   # per-material clippingPlanes (tape windows)

    # cde-window left-edge growth: shift the canvas (and any debug overlay
    # wraps) right by the same amount, so on-screen content stays put and
    # the new space on the left is usable for overlay corner handles
    @_leftInset = 0
    window.addEventListener 'cde-left-inset', (e) =>
      @_leftInset = e.detail
      @renderer.domElement.style.marginLeft = "#{@_leftInset}px"
      for k, o of (@_overlays ? {})
        o.wrap.style.left = "#{@_leftInset}px"

    @renderPass = new RenderPass(@scene, @camera)
    # @effectCopy = new ShaderPass(THREE.CopyShader)
    # @effectCopy.renderToScreen = true

    @composer = new EffectComposer(@renderer)
    @composer.setSize(@widthPx*@superRatio, @heightPx*@superRatio)

    @composer.addPass(@renderPass)
    # @composer.addPass(@effectCopy)

    @animate()

  animate: () =>
    requestAnimationFrame( @animate )
    @render()

  clear: () ->
    for child in @scene.children.slice(0).reverse()
      @scene.remove child
      if child? and child.geometry?
        child.geometry.dispose()

  # render: () ->
  #   # JSC-18820/p.144 - The flash rate for characters is 1Hz with 5/8 second
  #   # "on" time and 3/8 second "off" time.
  #   blinkOn = ((performance.now()/1000)%1) < (5/8)

  #   oldVal = @vectorMat.uniforms.opacity.value
  #   @vectorMat.uniforms.opacity.value = blinkOn
  #   if oldVal != blinkOn
  #     @dirty = true
  #   if @dirty
  #     @composer.render()
  #     @dirty = false

  render: () ->
    # keep the SDF line materials in sync with the framebuffer size so the
    # screen-space stroke width stays constant in display pixels
    @renderer.getDrawingBufferSize(@_dbSize ?= new THREE.Vector2())
    unless @_dbSize.equals(@resolutionU.value)
      @resolutionU.value.copy(@_dbSize)
      @pxRatioU.value = @_dbSize.x / @widthPx
      @dirty = true

    # dirty-gated: the rAF loop spins, but the scene only re-renders when
    # something marked it dirty (feed updates, menu changes, key echoes...)
    return unless @dirty
    @composer.render()
    @dirty = false


  add: (gl) ->
    for geom in gl
      @scene.add geom

  del: (gl) ->
    for geom in gl
      @scene.remove geom
      if geom.geometry?
        geom.geometry.dispose()

  str: (x,y,s,color=@c2h.cyan,scale=1.0,advance=1.0,scalex=1.0,charGen=@deuFont,rot=0,centered=false,clip=null) ->
    xx=x
    group = new THREE.Object3D()
    group.name = s
    for c in s
      if c == '\n'
        y+=1*scale
        xx = x-1
      geoms = charGen.drawGlyph(@,undefined, c, xx, y, color, scale, scalex, rot, centered, clip)
      for geom in geoms
        group.add(geom)
      xx = xx+advance
    return group

  strMEDS: (x,y,s,color=@c2h.cyan,scale=1.0,advance=0.62,scalex=1.0,clip=null) ->
    @str(x,y,s,color,scale,advance,scalex,@medsFont,0,false,clip)

  strCond: (x,y,s,color=@c2h.cyan,scale=1.0,advance=1.0) ->
    @str x,y,s,color,scale,advance, 1.0, @deuFont

  strCtrReg: (x,y,s,color=@c2h.cyan,scale=1.0,cw=51) ->
    xx = (cw-s.length-1)/2
    @str x+xx,y,s,color,scale,1.0,1.0,@deuFont

  strCtr: (y,s,color=@c2h.cyan,scale=1.0,cw=52) ->
    xx = (cw-s.length)/2
    @strCond xx,y,s,color,scale

  arrow: (x, color=@c2h.cyan) ->
      @line([
          [x+2.85, 36.25],
          [x+2.85, 35.46],
          [x+1.35,  35.46],
          [x+4.10, 34.41],
          [x+6.6,35.46],
          [x+5.28, 35.46],
          [x+5.28, 36.25]
      ], color)

  # four clipping planes bounding a clipBox = Vector4(xMin,xMax,yMin,yMax) in
  # display col/row coords (which equal world coords for these ortho displays)
  clipPlanes: (cb) ->
    [
      new THREE.Plane(new THREE.Vector3( 1, 0, 0), -cb.x)   # keep x >= xMin
      new THREE.Plane(new THREE.Vector3(-1, 0, 0),  cb.y)   # keep x <= xMax
      new THREE.Plane(new THREE.Vector3( 0, 1, 0), -cb.z)   # keep y >= yMin
      new THREE.Plane(new THREE.Vector3( 0,-1, 0),  cb.w)   # keep y <= yMax
    ]

  # clip to a window (tape) by cloning a shared material with clippingPlanes
  _clipMat: (material, clip) ->
    return material unless clip? and clip != @NO_CLIP
    material = material.clone()
    material.clippingPlanes = @clipPlanes(clip)
    # clone() deep-copies uniforms; re-share the screen-size refs
    material.uniforms.resolution = @resolutionU
    material.uniforms.pxRatio = @pxRatioU
    return material

  line: (coords, color=@c2h.cyan, intensity=1.0, clip=null) ->
    # legacy callers (menu edgekey titles) pass a THREE material as the color;
    # the old THREE.Line path silently ignored it and rendered the default
    # white hairline — keep that look (white, normal weight)
    if color?.isMaterial
      color = @c2h.white
    # color may be a spec {c, border, borderPx}: the stroke is drawn twice —
    # a widened underlay in the border color, then the core on top — giving
    # an SDF halo that sets the stroke off from its background. Cores render
    # at renderOrder 1 (above ALL borders) so crossing strokes don't notch
    # each other's halo.
    if color? and typeof color == 'object' and color.border?
      cc = color.c ? @c2h.white
      bp = color.borderPx ? 0.9
      key = "#{cc}|#{color.border}|#{bp}"
      @bMats ?= {}
      bMat = @bMats[key] ?= makeSDFLineMaterial(THREE, @sdfOpt({color: color.border, widthPx: @LINE_PX + 2*bp}))
      cMat = @mats[0][cc] ?= makeSDFLineMaterial(THREE, @sdfOpt({color: cc}))
      geom = makeSDFLineGeometry(THREE, coords)   # shared by both passes
      g = new THREE.Object3D()
      for [mat, order] in [[bMat, 0], [cMat, 1]]
        mesh = new THREE.Mesh(geom, @_clipMat(mat, clip))
        mesh.frustumCulled = false
        mesh.renderOrder = order
        g.add mesh
      return g
    # Intensity below full fades via opacity, in the stroke's colour.
    # Colours outside the c2h palette get a material built (and cached) on
    # demand, at either end.
    if intensity >= 0.999
      material = @mats[0][color] ?=
        makeSDFLineMaterial(THREE, @sdfOpt({color: color}))
    else
      lvl = Math.max(0, Math.min(@NINT-1, Math.round(intensity*(@NINT-1))))
      ramp = (@intMats[color] ?= [])
      material = ramp[lvl] ?=
        makeSDFLineMaterial(THREE, @sdfOpt({color: color, opacity: lvl/(@NINT-1)}))
    mesh = new THREE.Mesh(makeSDFLineGeometry(THREE, coords), @_clipMat(material, clip))
    mesh.frustumCulled = false   # quads are expanded in the vertex shader
    return mesh

  # Dashed variant of line() for DEU FEAT lineDash. Dash distances ride in
  # the geometry's segDist attribute (world units, like computeLineDistances).
  # Built on demand: a colour outside the palette has no entry here and
  # none in `@mats` either, and a missing material draws in THREE's default
  # with no dash.
  dashedLine: (coords, color=@c2h.cyan) ->
    material = @dashMats[color] ?=
      makeSDFLineMaterial(THREE, @sdfOpt({color: color, dashSize: 1.0, gapSize: 0.35}))
    mesh = new THREE.Mesh(makeSDFLineGeometry(THREE, coords), material)
    mesh.frustumCulled = false
    return mesh

  box: (x1, y1, x2, y2, color=@c2h.green, fillColor=undefined, clip=null) ->
    g = new THREE.Object3D()
    if fillColor
      fill = new THREE.MeshBasicMaterial({color:fillColor, side:THREE.DoubleSide})
      if clip? and clip != @NO_CLIP
        fill.clippingPlanes = @clipPlanes(clip)
      dl = new THREE.BufferGeometry()
      vertices = new Float32Array([
        x1, y1, 0,
        x2, y1, 0,
        x2, y2, 0,
        x1, y2, 0
      ])
      dl.setAttribute( 'position', new THREE.BufferAttribute( vertices, 3 ) );
      dl.setIndex([0,1,2, 0,2,3]);
      g.add new THREE.Mesh(dl,fill)
    if color
      g.add @line [[x1,y1],[x2,y1],[x2,y2],[x1,y2],[x1,y1]], color, 1.0, clip
    return g

  # filled convex polygon (triangle fan) with optional border, used for the
  # alpha-tape arrow readout
  polyFill: (pts, fillColor=@c2h.darkGray, borderColor=null, clip=null) ->
    g = new THREE.Object3D()
    verts = []
    for p in pts
      verts.push p[0], p[1], 0
    idx = []
    for i in [1...pts.length-1]
      idx.push 0, i, i+1
    geom = new THREE.BufferGeometry()
    geom.setAttribute('position', new THREE.Float32BufferAttribute(verts, 3))
    geom.setIndex(idx)
    mat = new THREE.MeshBasicMaterial({color: fillColor, side: THREE.DoubleSide})
    if clip? and clip != @NO_CLIP then mat.clippingPlanes = @clipPlanes(clip)
    g.add new THREE.Mesh(geom, mat)
    if borderColor then g.add @line(pts.concat([pts[0]]), borderColor, 1.0, clip)
    return g

  # DEBUG: overlay a reference screenshot as a free-form quad. Images live
  # in data/overlay_images/ — any of them can be selected live from the
  # param editor's 'reference overlay' group, and the chosen image persists
  # with the transform (in the live state and in each placement slot).
  # Drag the body to move; drag any of the 4 green corner handles to distort
  # (perspective warp for off-angle photos). Corners + opacity persist in
  # localStorage under `key`; `imgFile` is only the default for keys that
  # have never stored an image choice.
  toggleOverlay: (imgFile, key) ->
    @_overlays ?= {}
    if @_overlays[key]?
      o = @_overlays[key]
      o.wrap.style.display = if o.wrap.style.display == 'none' then 'block' else 'none'
      return
    BW = 640 ; BH = 640                                     # source rect size for the warp
    wrap = document.createElement('div')
    wrap.style.cssText = "position:absolute; left:#{@_leftInset ? 0}px; top:0; z-index:10000; -webkit-app-region:no-drag;"
    im = document.createElement('img')
    im.style.cssText = "position:absolute; left:0; top:0; width:#{BW}px; height:#{BH}px; transform-origin:0 0; opacity:0.5; cursor:move; border:1px solid #00ff00; box-sizing:border-box; -webkit-app-region:no-drag;"
    wrap.appendChild(im)
    curImg = imgFile
    loadImg = (name) =>
      try
        buf = fs.readFileSync(@CONFIG.NSTS_TOP + OVERLAY_DIR + name)
        mime = if /\.jpe?g$/i.test(name) then 'image/jpeg' else 'image/png'
        im.src = "data:#{mime};base64," + buf.toString('base64')
        curImg = name
      catch e
        console.log "overlay: can't read #{OVERLAY_DIR}#{name}: #{e}"
    corners = null ; opacity = 0.5
    try
      s = window.localStorage.getItem(key)
      if s
        g = JSON.parse(s)
        opacity = if isFinite(g.opacity) then g.opacity else 0.5
        if g.corners?.length == 4 then corners = g.corners
        else if isFinite(g.left) and isFinite(g.width)      # migrate old rect format
          corners = [[g.left,g.top],[g.left+g.width,g.top],[g.left,g.top+g.height],[g.left+g.width,g.top+g.height]]
    loadImg(if g?.img then g.img else imgFile)
    if corners?                                              # reject degenerate/collapsed saves
      xs = (p[0] for p in corners) ; ys = (p[1] for p in corners)
      unless (Math.max(xs...) - Math.min(xs...) >= 40) and (Math.max(ys...) - Math.min(ys...) >= 40)
        corners = null
    corners ?= [[40,40],[40+BW,40],[40,40+BH],[40+BW,40+BH]]  # TL, TR, BL, BR
    if g?.corners? and g.ver != 2      # one-time: contents moved up ~10px -> shift overlay to match
      corners = ([cx, cy-10] for [cx,cy] in corners)
      try window.localStorage.setItem(key, JSON.stringify({corners, opacity, ver:2}))
    im.style.opacity = opacity
    edges = [[0,1],[2,3],[0,2],[1,3]]                        # top, bottom, left, right (corner pairs)
    handles = (for i in [0...4]                              # corner handles (green squares)
      hd = document.createElement('div')
      hd.style.cssText = 'position:absolute; width:14px; height:14px; margin:-7px 0 0 -7px; background:#00ff00; border:1px solid #000; z-index:10001; cursor:crosshair; -webkit-app-region:no-drag;'
      wrap.appendChild(hd)
      hd)
    ehandles = (for i in [0...4]                             # edge handles (cyan diamonds) move both edge corners
      hd = document.createElement('div')
      hd.style.cssText = 'position:absolute; width:12px; height:12px; margin:-6px 0 0 -6px; background:#00ffff; border:1px solid #000; transform:rotate(45deg); z-index:10001; cursor:move; -webkit-app-region:no-drag;'
      wrap.appendChild(hd)
      hd)
    # rotate tool
    #
    # Double-click the image to set the rotation centre
    # (small red cross), then type a signed angle in degrees (fractions ok)
    # into the box below the image and hit Enter; + rotates clockwise.
    # Centre and cumulative angle persist with the corners.
    rotCenter = if g?.rotCenter?.length == 2 then g.rotCenter else null
    rotDeg = g?.rotDeg ? 0
    cross = document.createElement('div')
    cross.style.cssText = 'position:absolute; width:0; height:0; z-index:10002; display:none; pointer-events:none;'
    for [cw, ch, cl, ct] in [[15, 3, -7, -1], [3, 15, -1, -7]]
      bar = document.createElement('div')
      bar.style.cssText = "position:absolute; background:#ff2020; border:none; width:#{cw}px; height:#{ch}px; left:#{cl}px; top:#{ct}px;"
      cross.appendChild(bar)
    wrap.appendChild(cross)
    rotBox = document.createElement('div')
    rotBox.style.cssText = 'position:absolute; z-index:10002; display:none; background:#222; color:#7f7; font:12px monospace; padding:2px 5px; border:1px solid #7f7; -webkit-app-region:no-drag;'
    rotBox.appendChild(document.createTextNode('rot° '))
    rotInput = document.createElement('input')
    rotInput.type = 'text'
    rotInput.size = 7
    rotInput.style.cssText = 'background:#000; color:#7f7; border:1px solid #7f7; font:12px monospace; -webkit-app-region:no-drag;'
    rotBox.appendChild(rotInput)
    rotTot = document.createElement('span')
    rotTot.style.cssText = 'margin-left:6px;'
    rotBox.appendChild(rotTot)
    wrap.appendChild(rotBox)
    # nudge tool
    #
    # Double-click any corner/edge handle for fine (sub-px)
    # position adjustments. Arrow buttons / arrow keys move the selected
    # handle by the step size; the x/y boxes take exact coordinates (edges
    # use their midpoint — moving it shifts both of that edge's corners).
    nudgeSel = null
    nudgeBox = document.createElement('div')
    nudgeBox.style.cssText = 'position:absolute; z-index:10003; display:none; background:#222; color:#7f7; font:12px monospace; padding:3px 6px; border:1px solid #7f7; white-space:nowrap; -webkit-app-region:no-drag;'
    nTitle = document.createElement('span')
    nTitle.style.cssText = 'margin-right:6px; color:#2df;'
    nudgeBox.appendChild(nTitle)
    mkIn = (sz) ->
      inp = document.createElement('input')
      inp.type = 'text' ; inp.size = sz
      inp.style.cssText = 'background:#000; color:#7f7; border:1px solid #575; font:12px monospace; margin:0 3px;'
      inp
    nudgeBox.appendChild(document.createTextNode('x'))
    nX = mkIn(7) ; nudgeBox.appendChild(nX)
    nudgeBox.appendChild(document.createTextNode('y'))
    nY = mkIn(7) ; nudgeBox.appendChild(nY)
    nudgeBox.appendChild(document.createTextNode(' step'))
    nStep = mkIn(4) ; nStep.value = '0.25' ; nudgeBox.appendChild(nStep)
    for [sym, ndx, ndy] in [['◀',-1,0],['▶',1,0],['▲',0,-1],['▼',0,1]]
      bt = document.createElement('button')
      bt.textContent = sym
      bt.style.cssText = 'font:11px monospace; margin:0 1px;'
      do (ndx, ndy) ->
        bt.addEventListener 'click', (e) ->
          s = parseFloat(nStep.value) ; s = 0.25 unless isFinite(s) and s
          nudgeBy(ndx*s, ndy*s)
          e.stopPropagation()
      nudgeBox.appendChild(bt)
    nClose = document.createElement('button')
    nClose.textContent = '×'
    nClose.style.cssText = 'font:11px monospace; margin-left:5px;'
    nClose.addEventListener 'click', -> selectHandle(null)
    nudgeBox.appendChild(nClose)
    wrap.appendChild(nudgeBox)
    document.body.appendChild(wrap)
    @_overlays[key] = {wrap, im, corners}
    apply = =>
      @_warpImg(im, BW, BH, corners)
      for hd,i in handles
        hd.style.left = corners[i][0]+'px' ; hd.style.top = corners[i][1]+'px'
      for hd,i in ehandles
        [a,b] = edges[i]
        hd.style.left = (corners[a][0]+corners[b][0])/2+'px' ; hd.style.top = (corners[a][1]+corners[b][1])/2+'px'
      # entry boxes live below the image quad, outside its area
      xs = (p[0] for p in corners) ; ys = (p[1] for p in corners)
      if rotCenter?
        cross.style.display = 'block'
        cross.style.left = rotCenter[0]+'px' ; cross.style.top = rotCenter[1]+'px'
        rotBox.style.display = 'block'
        rotBox.style.left = Math.min(xs...)+'px'
        rotBox.style.top = (Math.max(ys...) + 12)+'px'
        rotTot.textContent = "Σ #{rotDeg.toFixed(2)}°"
      if nudgeSel?
        nudgeBox.style.left = Math.min(xs...)+'px'
        nudgeBox.style.top = (Math.max(ys...) + 44)+'px'
    save = ->
      try window.localStorage.setItem(key, JSON.stringify({corners, opacity: parseFloat(im.style.opacity), ver:2, rotCenter, rotDeg, img: curImg}))
    @_overlays[key].save = save
    # placement-slot support (see overlaySlot* methods): capture the full
    # live placement, and restore one — updating the closure state the
    # drag/rotate handlers work from. The image choice rides along; a
    # legacy snapshot without one keeps whatever image is showing.
    @_overlays[key].state = -> {corners: (c.slice() for c in corners), opacity: parseFloat(im.style.opacity), ver: 2, rotCenter: (rotCenter?.slice() ? null), rotDeg, img: curImg}
    @_overlays[key].load = (st) ->
      return unless st?.corners?.length == 4
      loadImg(st.img) if st.img? and st.img != curImg
      for c, i in st.corners
        corners[i] = [c[0], c[1]]
      opacity = if isFinite(st.opacity) then st.opacity else opacity
      im.style.opacity = opacity
      rotCenter = if st.rotCenter?.length == 2 then st.rotCenter.slice() else null
      rotDeg = st.rotDeg ? 0
      apply()
      save()
    # live image switching (param-editor 'image' pulldown): the transform
    # stays put — only the picture changes — and the choice saves into the
    # live state, so it lands in the current slot on the next slot stash
    @_overlays[key].img = -> curImg
    @_overlays[key].setImage = (name) -> (loadImg(name) ; save())
    # migration: bind the image into records saved before images were
    # selectable, so the current tuned work stays attached to its picture
    save() unless g?.img?
    rotateBy = (deg) ->
      return unless rotCenter?
      th = deg * Math.PI / 180                # + = clockwise (y down)
      cs = Math.cos(th) ; sn = Math.sin(th)
      [cx, cy] = rotCenter
      for c, i in corners
        dx = c[0] - cx ; dy = c[1] - cy
        corners[i] = [cx + dx*cs - dy*sn, cy + dx*sn + dy*cs]
      rotDeg += deg
      apply() ; save()
    im.addEventListener 'dblclick', (e) ->
      rc = wrap.getBoundingClientRect()
      rotCenter = [e.clientX - rc.left, e.clientY - rc.top]
      apply() ; save()
      rotInput.focus()
      e.preventDefault() ; e.stopPropagation()
    rotInput.addEventListener 'keydown', (e) ->
      e.stopPropagation()          # keep the DPS/edge-key handlers out of typing
      if e.key == 'Enter'
        deg = parseFloat(rotInput.value)
        rotateBy(deg) if isFinite(deg) and deg
        rotInput.value = ''
      else if e.key == 'Escape'
        rotInput.blur()
    rotInput.addEventListener 'keyup', (e) -> e.stopPropagation()
    rotInput.addEventListener 'mousedown', (e) -> e.stopPropagation()
    # nudge-tool plumbing
    nudgePos = ->
      return null unless nudgeSel?
      if nudgeSel.type == 'corner' then corners[nudgeSel.i].slice()
      else
        [a, b] = edges[nudgeSel.i]
        [(corners[a][0]+corners[b][0])/2, (corners[a][1]+corners[b][1])/2]
    nudgeUI = ->
      return unless nudgeSel?
      names = if nudgeSel.type == 'corner' then ['TL','TR','BL','BR'] else ['top','bottom','left','right']
      nTitle.textContent = "#{nudgeSel.type} #{names[nudgeSel.i]}"
      p = nudgePos()
      nX.value = p[0].toFixed(2) ; nY.value = p[1].toFixed(2)
    nudgeBy = (ndx, ndy) ->
      return unless nudgeSel?
      idxs = if nudgeSel.type == 'corner' then [nudgeSel.i] else edges[nudgeSel.i]
      for i in idxs
        corners[i] = [corners[i][0]+ndx, corners[i][1]+ndy]
      apply() ; save() ; nudgeUI()
    selectHandle = (sel) ->
      hd.style.outline = '' for hd in handles.concat(ehandles)
      nudgeSel = sel
      if not sel?
        nudgeBox.style.display = 'none'
        return
      hd = (if sel.type == 'corner' then handles else ehandles)[sel.i]
      hd.style.outline = '2px solid #ff2020'
      nudgeBox.style.display = 'block'
      nudgeUI()
      apply()                    # positions the box below the image
      nStep.focus() ; nStep.select()
    nXY = ->
      return unless nudgeSel?
      x = parseFloat(nX.value) ; y = parseFloat(nY.value)
      return unless isFinite(x) and isFinite(y)
      p = nudgePos()
      nudgeBy(x - p[0], y - p[1])
    for inp in [nX, nY]
      inp.addEventListener 'change', nXY
      inp.addEventListener 'keydown', (e) -> (nXY() if e.key == 'Enter')
    nudgeBox.addEventListener 'keydown', (e) ->
      e.stopPropagation()        # keep DPS/edge-key handlers out of typing
      dd = {ArrowLeft:[-1,0], ArrowRight:[1,0], ArrowUp:[0,-1], ArrowDown:[0,1]}[e.key]
      if dd?
        s = parseFloat(nStep.value) ; s = 0.25 unless isFinite(s) and s
        nudgeBy(dd[0]*s, dd[1]*s)
        e.preventDefault()
    nudgeBox.addEventListener 'keyup', (e) -> e.stopPropagation()
    nudgeBox.addEventListener 'mousedown', (e) -> e.stopPropagation()
    for hd, i in handles
      do (i) ->
        handles[i].addEventListener 'dblclick', (e) ->
          selectHandle({type: 'corner', i: i})
          e.preventDefault() ; e.stopPropagation()
    for hd, i in ehandles
      do (i) ->
        ehandles[i].addEventListener 'dblclick', (e) ->
          selectHandle({type: 'edge', i: i})
          e.preventDefault() ; e.stopPropagation()
    apply()
    cdrag = null ; edrag = null ; bdrag = null
    for hd, i in handles
      do (i) ->
        handles[i].addEventListener 'mousedown', (e) ->
          cdrag = {i:i, x:e.clientX, y:e.clientY, cx:corners[i][0], cy:corners[i][1]}
          e.preventDefault() ; e.stopPropagation()
    for hd, i in ehandles
      do (i) ->
        ehandles[i].addEventListener 'mousedown', (e) ->
          [a,b] = edges[i]
          edrag = {a:a, b:b, x:e.clientX, y:e.clientY, ca:corners[a].slice(), cb:corners[b].slice()}
          e.preventDefault() ; e.stopPropagation()
    im.addEventListener 'mousedown', (e) ->
      bdrag = {x:e.clientX, y:e.clientY, start:(cc.slice() for cc in corners)}
      e.preventDefault()
    window.addEventListener 'mousemove', (e) ->
      if cdrag?
        corners[cdrag.i] = [cdrag.cx + e.clientX - cdrag.x, cdrag.cy + e.clientY - cdrag.y]
        apply()
      else if edrag?
        dx = e.clientX - edrag.x ; dy = e.clientY - edrag.y
        corners[edrag.a] = [edrag.ca[0]+dx, edrag.ca[1]+dy]
        corners[edrag.b] = [edrag.cb[0]+dx, edrag.cb[1]+dy]
        apply()
      else if bdrag?
        dx = e.clientX - bdrag.x ; dy = e.clientY - bdrag.y
        corners[k] = [bdrag.start[k][0]+dx, bdrag.start[k][1]+dy] for k in [0...4]
        apply()
    window.addEventListener 'mouseup', ->
      if cdrag? or edrag? or bdrag? then cdrag = null ; edrag = null ; bdrag = null ; save()
    console.log "overlay #{curImg}: drag body to move, green corners to distort, cyan edges to resize; Shift cycles opacity; dbl-click sets the rotate centre, then enter ± degrees below"

  cycleOverlayOpacity: (key) ->
    o = @_overlays?[key]
    return unless o?
    steps = [0.25, 0.5, 0.75, 1.0]
    cur = parseFloat(o.im.style.opacity) or 0.5
    o.im.style.opacity = steps.find((s) -> s > cur + 0.01) ? steps[0]
    # o.save preserves the rotate-tool state alongside corners/opacity
    if o.save? then o.save()
    else try window.localStorage.setItem(key, JSON.stringify({corners:o.corners, opacity: parseFloat(o.im.style.opacity), ver:2}))

  # overlay image library (debug)
  #
  # The reference-overlay image is selectable from data/overlay_images/ via
  # the param editor's 'reference overlay' group. The choice binds to the
  # placement: it lives in the live state (localStorage `key`.img) and rides
  # into slot snapshots with the transform.
  overlayImageNames: () ->
    try
      (f for f in fs.readdirSync(@CONFIG.NSTS_TOP + OVERLAY_DIR) when /\.(png|jpe?g|gif|webp)$/i.test(f)).sort()
    catch e
      console.log "overlay: can't list #{OVERLAY_DIR}: #{e}"
      []
  overlayImageCur: (key, dflt) ->
    o = @_overlays?[key]
    return o.img() if o?.img?
    ((try JSON.parse(window.localStorage.getItem(key)))?.img) ? dflt
  overlayImageSelect: (key, name) ->
    o = @_overlays?[key]
    if o?.setImage?
      o.setImage(name)
    else
      # overlay not built yet: bind the choice into the stored live state
      st = (try JSON.parse(window.localStorage.getItem(key))) ? {}
      st.img = name
      try window.localStorage.setItem(key, JSON.stringify(st))
    name
  overlayVisible: (key) ->
    o = @_overlays?[key]
    o? and o.wrap.style.display != 'none'

  # overlay placement slots (debug)
  #
  # Named save slots for a reference overlay's placement (corners, opacity,
  # rotate-tool state). localStorage layout: registry at `<key>:slots` =
  # {names:[...], cur}, each slot's snapshot at `<key>#<name>`; the LIVE
  # placement stays at `<key>` itself (the drag handlers keep writing it).
  # Driven from the param-editor pulldowns (screen testControls): selecting
  # a slot stashes the live placement into the outgoing slot and loads the
  # incoming one; selecting 'new' mints a fresh slot copying the live
  # placement and makes it current.
  _ovSlots: (key) ->
    idx = try JSON.parse(window.localStorage.getItem("#{key}:slots"))
    idx = {} unless idx? and typeof idx == 'object'
    idx.names = ['1'] unless idx.names?.length
    idx.cur = idx.names[0] unless idx.cur? and idx.cur in idx.names
    idx
  overlaySlotNames: (key) -> @_ovSlots(key).names.concat ['new']
  overlaySlotCur: (key) -> @_ovSlots(key).cur
  # hooks (screen-provided, see MDUScreen.ovHooks): slot snapshots also
  # capture the screen's feed values via hooks.getData, and restoring a
  # slot re-applies them via hooks.setData when 'apply values' is enabled
  overlaySlotSelect: (key, name, hooks) ->
    idx = @_ovSlots(key)
    o = @_overlays?[key]
    live = o?.state?() ? (try JSON.parse(window.localStorage.getItem(key)))
    if live? and hooks?.getData?
      live.data = hooks.getData()
    if name == 'new'
      n = 1
      n++ while "#{n}" in idx.names
      name = "#{n}"
      idx.names.push name
      # eager copy so the slot survives even if never switched away from
      try window.localStorage.setItem("#{key}##{name}", JSON.stringify(live)) if live?
      console.log "overlay #{key}: new slot #{name} (copy of #{idx.cur})"
    else
      return idx.cur unless name in idx.names
      if name != idx.cur
        # stash the live placement into the outgoing slot, load the new one
        try window.localStorage.setItem("#{key}##{idx.cur}", JSON.stringify(live)) if live?
        st = try JSON.parse(window.localStorage.getItem("#{key}##{name}"))
        if st?
          if o?.load? then o.load(st)
          else try window.localStorage.setItem(key, JSON.stringify(st))
          # re-configure the screen to the slot's captured feed values
          if st.data? and hooks?.setData? and @overlayApplyVals(key)
            hooks.setData(st.data)
    idx.cur = name
    try window.localStorage.setItem("#{key}:slots", JSON.stringify(idx))
    name

  # 'apply values' checkbox state (per overlay key, persists): whether
  # restoring a slot also re-applies its captured feed values. Turning it
  # ON applies the current slot's values immediately.
  overlayApplyVals: (key) ->
    (try window.localStorage.getItem("#{key}:applyVals")) == '1'
  overlayApplyValsSet: (key, v, hooks) ->
    try window.localStorage.setItem("#{key}:applyVals", if v then '1' else '0')
    if v and hooks?.setData?
      st = try JSON.parse(window.localStorage.getItem("#{key}##{@overlaySlotCur(key)}"))
      hooks.setData(st.data) if st?.data?
    !!v

  # map the img source rect (0,0)-(w,h) onto 4 quad corners [TL,TR,BL,BR] via a
  # CSS matrix3d homography (standard basis-to-points projective transform)
  _warpImg: (elt, w, h, corners) ->
    adj = (m) -> [
      m[4]*m[8]-m[5]*m[7], m[2]*m[7]-m[1]*m[8], m[1]*m[5]-m[2]*m[4],
      m[5]*m[6]-m[3]*m[8], m[0]*m[8]-m[2]*m[6], m[2]*m[3]-m[0]*m[5],
      m[3]*m[7]-m[4]*m[6], m[1]*m[6]-m[0]*m[7], m[0]*m[4]-m[1]*m[3]]
    mmm = (a,b) ->
      c = (0 for _ in [0...9])
      for i in [0...3]
        for j in [0...3]
          sum = 0
          sum += a[3*i+k]*b[3*k+j] for k in [0...3]
          c[3*i+j] = sum
      c
    mmv = (m,v) -> [m[0]*v[0]+m[1]*v[1]+m[2]*v[2], m[3]*v[0]+m[4]*v[1]+m[5]*v[2], m[6]*v[0]+m[7]*v[1]+m[8]*v[2]]
    basis = (x1,y1,x2,y2,x3,y3,x4,y4) ->
      m = [x1,x2,x3, y1,y2,y3, 1,1,1]
      v = mmv(adj(m), [x4,y4,1])
      mmm(m, [v[0],0,0, 0,v[1],0, 0,0,v[2]])
    [a,b,cc,d] = corners
    s = basis(0,0, w,0, 0,h, w,h)
    dd = basis(a[0],a[1], b[0],b[1], cc[0],cc[1], d[0],d[1])
    t = mmm(dd, adj(s))
    t = (v/t[8] for v in t)
    elt.style.transform = "matrix3d(#{[t[0],t[3],0,t[6], t[1],t[4],0,t[7], 0,0,1,0, t[2],t[5],0,t[8]].join(',')})"

  quad: (v, color=@c2h.green, fillColor=undefined) ->
    g = new THREE.Object3D()
    if fillColor
      fill = new THREE.MeshBasicMaterial({color:fillColor, side:THREE.DoubleSide})
      dl = new THREE.BufferGeometry()
      vertices = new Float32Array(v)
      dl.setAttribute( 'position', new THREE.BufferAttribute( vertices, 3 ) );
      dl.setIndex([0,1,2, 0,2,3]);
      g.add new THREE.Mesh(dl,fill)
    # if color
    #   g.add @line [[x1,y1],[x2,y1],[x2,y2],[x1,y2],[x1,y1]], color, clip
    return g


  tri: (x1, y1, x2, y2, x3, y3, color=@c2h.green,fillColor=undefined) ->

    if fillColor
      fill = new THREE.MeshBasicMaterial({color:fillColor, side:THREE.DoubleSide})
      dl = new THREE.BufferGeometry()
      vertices = new Float32Array([
        x1, y1, 0, 
        x2, y2, 0,
        x3, y3, 0
      ])
      dl.setAttribute( 'position', new THREE.BufferAttribute( vertices, 3 ) );
      dl.setIndex([0,1,2])
      return new THREE.Mesh(dl,fill)
    else
      return @line [[x1,y1],[x2,y2],[x3,y3]], color

  # asp: x aspect factor. Default 1.47222 is the empirical row->col stretch
  # matching the MEDS reference imagery. Pass 1 when drawing inside a group
  # that already applies its own x scale (e.g. the ADI circular space, which
  # uses 1.3632 [= drawGlyph AR, a true circle] times a tunable stretch).
  arc: (x,y,r,sa,ea, color=@c2h.darkGray, asp=1.47222) ->
    l = []
    for a in [sa...ea+1]
      l.push [x + (r*Math.cos(deg2rad(a)))*asp,
              y + (r*Math.sin(deg2rad(a)))*(1.00)]
    return @line l, color

  filledArc: (x,y,r,sa,ea, color=0x333333) ->
    earcut = require('earcut')
    l = []
    dl = new THREE.BufferGeometry()
    for a in [sa...ea+1]
      x0 = x + (r*Math.cos(deg2rad(a)))*(1.47222)
      y0 = y + r*Math.sin(deg2rad(a))
      l = l.concat [x0, y0]
      #vertices.push(x0,y0,-1)
    vertices = new Float32Array(l)
    dl.setAttribute( 'position', new THREE.BufferAttribute( vertices, 3 ) );  
    pts =  earcut(l)
    faces = []
    for e,i in pts by 3
      faces.push(pts[i], pts[i+1], pts[i+2])
    dl.setIndex(faces)
    fill = new THREE.MeshBasicMaterial({color:color, side:THREE.DoubleSide})
    return new THREE.Mesh(dl,fill)

  arcTicks: (x, y, r, sa, ea, step, len, color=@c2h.darkGray, asp=1.47222) ->
    ticks = new THREE.Object3D()
    ticks.name = "ticks"
    for a in [sa...ea+1] by step
      cp = [x + (r*Math.cos(deg2rad(a)))*asp, y + r*Math.sin(deg2rad(a))]
      cpn = [x + ((r+len)*Math.cos(deg2rad(a)))*asp,
             y + (r+len)*Math.sin(deg2rad(a))]
      ticks.add @line [cp,cpn], color
    return ticks

  arcLabels: (x, y, r, sa, ea, step, len, labelTxt, color=@c2h.darkGray, scale=0.9) ->
    labels = new THREE.Object3D()
    labels.name = "arcLabels"
    i = 0
    for a in [sa...ea+1] by step
      cpn = [x + ((r+len)*Math.cos(deg2rad(a)))*(1.47222),
             y + (r+len)*Math.sin(deg2rad(a))]
      labels.add @strMEDS cpn[0], cpn[1], labelTxt[i], color, scale, 0.9, 1.0
      i++
    return labels

  arcArrow: (x, y, r, a, color=@c2h.green) ->

  tickScale: (x1,y1,x2,y2, step, len, color=@c2h.darkGray) ->

  drawClipWin: (clipBox) ->
      console.log("CLIP")
      console.log(clipBox)
      m = new THREE.MeshBasicMaterial {side:THREE.DoubleSide, wireframe:false, color:@c2h.darkGreen}
      
      g = new THREE.BufferGeometry()
      v = new Float32Array( [
        0,          0, 0,           # 0
        clipBox.x, 0, 0,           # 1
        clipBox.y, 0, 0,           # 2
        53,         0, 0,           # 3
        
        0,          clipBox.z, 0,  # 4
        clipBox.x, clipBox.z, 0,  # 5
        clipBox.y, clipBox.z, 0,  # 6
        53,         clipBox.z, 0,  # 7
        
        0,          clipBox.w, 0,  # 8
        clipBox.x, clipBox.w, 0,  # 9
        clipBox.y, clipBox.w, 0,  # 10
        53,         clipBox.w, 0,  # 11
        
        0,          37,         0,  # 12
        clipBox.x, 37,         0,  # 13
        clipBox.y, 37,         0,  # 14
        53,         37,         0   # 16
      ])
      i = [0, 1, 12, 12, 1, 13,
          1, 2, 5, 5, 2, 6, 
          2, 3, 14, 14, 3, 15,
          9, 10, 13, 13, 10, 14
          ]
      console.log(v)
      console.log(i)
      # menuMask = new THREE.PlaneGeometry(52, 5)
      g.setIndex(i)
      g.setAttribute('position', new THREE.Float32BufferAttribute( v, 3 ))
      console.log(g)
      m = new THREE.Mesh(g, m)
      m.position.z = 0
      m = new THREE.Object3D()
      m.add @strMEDS clipBox.x, clipBox.y, "UL"
      m.add @strMEDS clipBox.z, clipBox.w, "LR"
      return m
