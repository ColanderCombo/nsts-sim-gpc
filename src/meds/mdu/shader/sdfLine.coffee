# SDF (signed-distance-field) polyline renderer.
#
# Each segment of the polyline becomes one screen-aligned quad. The vertex
# shader projects both endpoints, expands the quad in *screen pixel* space
# (so stroke width is uniform regardless of the display's anisotropic
# world-unit scales), and the fragment shader evaluates the exact distance
# from the pixel to the segment (capsule SDF), feathering the edge with
# smoothstep. Result: smooth, thick, antialiased strokes with round caps
# and round joins at any angle. Dashes are carried as a per-segment
# cumulative-distance attribute (world units, matching LineDashedMaterial
# semantics) and get the same soft edges.

SDF_VERT = """
  uniform vec2 resolution;
  uniform float halfWidthPx;
  uniform float aaPx;
  uniform float pxRatio;
  attribute vec3 endA;
  attribute vec3 endB;
  attribute vec2 corner;
  attribute vec2 segDist;
  varying vec2 vA;
  varying vec2 vB;
  varying vec2 vDist;
  #include <clipping_planes_pars_vertex>

  void main() {
    vec4 clipA = projectionMatrix * modelViewMatrix * vec4(endA, 1.0);
    vec4 clipB = projectionMatrix * modelViewMatrix * vec4(endB, 1.0);
    vec2 sA = (clipA.xy / clipA.w * 0.5 + 0.5) * resolution;
    vec2 sB = (clipB.xy / clipB.w * 0.5 + 0.5) * resolution;
    vec2 ab = sB - sA;
    float len = length(ab);
    // zero-length segment renders as a round dot via the cap expansion
    vec2 dir = len > 1e-6 ? ab / len : vec2(1.0, 0.0);
    vec2 nrm = vec2(-dir.y, dir.x);
    float ext = (halfWidthPx + aaPx) * pxRatio + 1.0;
    vec2 sP = mix(sA, sB, corner.x)
            + dir * (corner.x * 2.0 - 1.0) * ext   // extend past ends for caps
            + nrm * corner.y * ext;                // widen across the line
    float cw = mix(clipA.w, clipB.w, corner.x);
    float cz = mix(clipA.z, clipB.z, corner.x);
    gl_Position = vec4((sP / resolution * 2.0 - 1.0) * cw, cz, cw);
    vA = sA;
    vB = sB;
    vDist = segDist;
    // clip-test position of the ACTUAL expanded corner, not the segment
    // endpoint: convert the screen-px expansion back to view units via the
    // ortho projection scale (exact for these ortho displays). Using the
    // endpoint alone makes plane clipping cut perpendicular to the stroke
    // (chunky mis-angled cutoffs on diagonal strokes, e.g. the alpha
    // tape's Max L/D diamond).
    vec4 mvPosition = modelViewMatrix * vec4(mix(endA, endB, corner.x), 1.0);
    vec2 ndcOff = (sP - mix(sA, sB, corner.x)) / resolution * 2.0;
    mvPosition.xy += ndcOff / vec2(projectionMatrix[0][0], projectionMatrix[1][1]);
    #include <clipping_planes_vertex>
  }
"""

SDF_FRAG = """
  uniform vec3 diffuse;
  uniform float opacity;
  uniform float halfWidthPx;
  uniform float aaPx;
  uniform float pxRatio;
  uniform float dashSize;
  uniform float gapSize;
  varying vec2 vA;
  varying vec2 vB;
  varying vec2 vDist;
  #include <clipping_planes_pars_fragment>

  void main() {
    #include <clipping_planes_fragment>
    vec2 ba = vB - vA;
    float l2 = dot(ba, ba);
    float t = l2 > 0.0 ? clamp(dot(gl_FragCoord.xy - vA, ba) / l2, 0.0, 1.0) : 0.0;
    float d = distance(gl_FragCoord.xy, vA + ba * t);
    float hw = halfWidthPx * pxRatio;
    float aa = max(aaPx * pxRatio, 1e-3);
    float alpha = 1.0 - smoothstep(hw - aa, hw + aa, d);
    if (gapSize > 0.0) {
      float lineD = mix(vDist.x, vDist.y, t);
      float period = dashSize + gapSize;
      float dw = mod(lineD, period);
      float hd = dashSize * 0.5;
      // soften dash ends by the same feather, converted to world units
      float soft = max(aa * (vDist.y - vDist.x) / max(sqrt(l2), 1e-3), 1e-4);
      alpha *= 1.0 - smoothstep(hd - soft, hd + soft, abs(dw - hd));
    }
    alpha *= opacity;
    if (alpha < 0.004) discard;
    gl_FragColor = vec4(diffuse, alpha);
  }
"""

# One quad (4 verts / 6 indices) per segment. Endpoints ride along as
# attributes so the fragment shader can evaluate the true segment SDF.
# `position` is filled with the endpoint coords only so three.js internals
# (raycast/bounds) have something sane; render extents come from the
# vertex-shader expansion, so meshes using this should set frustumCulled=false.
export makeSDFLineGeometry = (THREE, coords, z=100) ->
  geom = new THREE.BufferGeometry()
  n = Math.max(0, (coords?.length ? 0) - 1)
  pos     = new Float32Array(n*4*3)
  endA    = new Float32Array(n*4*3)
  endB    = new Float32Array(n*4*3)
  corner  = new Float32Array(n*4*2)
  segDist = new Float32Array(n*4*2)
  idx     = new (if n*4 > 65535 then Uint32Array else Uint16Array)(n*6)
  dist = 0
  for i in [0...n]
    a = coords[i]
    b = coords[i+1]
    az = a[2] ? z
    bz = b[2] ? z
    d0 = dist
    dist += Math.hypot(b[0]-a[0], b[1]-a[1])
    for k in [0...4]
      v = i*4 + k
      onB = k >> 1                        # verts 0,1 sit at A; 2,3 at B
      side = if k & 1 then 1 else -1      # which side of the line to widen
      p = if onB then b else a
      pos.set [p[0], p[1], (if onB then bz else az)], v*3
      endA.set [a[0], a[1], az], v*3
      endB.set [b[0], b[1], bz], v*3
      corner.set [onB, side], v*2
      segDist.set [d0, dist], v*2
    idx.set [i*4, i*4+2, i*4+1,  i*4+2, i*4+3, i*4+1], i*6
  geom.setAttribute 'position', new THREE.BufferAttribute(pos, 3)
  geom.setAttribute 'endA',     new THREE.BufferAttribute(endA, 3)
  geom.setAttribute 'endB',     new THREE.BufferAttribute(endB, 3)
  geom.setAttribute 'corner',   new THREE.BufferAttribute(corner, 2)
  geom.setAttribute 'segDist',  new THREE.BufferAttribute(segDist, 2)
  geom.setIndex new THREE.BufferAttribute(idx, 1)
  return geom

# Batched variant: many disjoint polylines in one BufferGeometry (a single
# draw call). Used for the ADI ball markings (~thousands of tiny segments).
# Attribute layout matches makeSDFLineGeometry; polylines simply don't share
# quads at their boundaries, and dash distances restart per polyline.
export makeSDFLinesGeometry = (THREE, polylines, z=100) ->
  n = 0
  for pl in polylines
    n += Math.max(0, (pl?.length ? 0) - 1)
  geom = new THREE.BufferGeometry()
  pos     = new Float32Array(n*4*3)
  endA    = new Float32Array(n*4*3)
  endB    = new Float32Array(n*4*3)
  corner  = new Float32Array(n*4*2)
  segDist = new Float32Array(n*4*2)
  idx     = new (if n*4 > 65535 then Uint32Array else Uint16Array)(n*6)
  s = 0
  for pl in polylines
    continue unless pl? and pl.length > 1
    dist = 0
    for i in [0...pl.length-1]
      a = pl[i]
      b = pl[i+1]
      az = a[2] ? z
      bz = b[2] ? z
      d0 = dist
      dist += Math.hypot(b[0]-a[0], b[1]-a[1], bz-az)
      for k in [0...4]
        v = s*4 + k
        onB = k >> 1
        side = if k & 1 then 1 else -1
        p = if onB then b else a
        pos.set [p[0], p[1], (if onB then bz else az)], v*3
        endA.set [a[0], a[1], az], v*3
        endB.set [b[0], b[1], bz], v*3
        corner.set [onB, side], v*2
        segDist.set [d0, dist], v*2
      idx.set [s*4, s*4+2, s*4+1,  s*4+2, s*4+3, s*4+1], s*6
      s++
  geom.setAttribute 'position', new THREE.BufferAttribute(pos, 3)
  geom.setAttribute 'endA',     new THREE.BufferAttribute(endA, 3)
  geom.setAttribute 'endB',     new THREE.BufferAttribute(endB, 3)
  geom.setAttribute 'corner',   new THREE.BufferAttribute(corner, 2)
  geom.setAttribute 'segDist',  new THREE.BufferAttribute(segDist, 2)
  geom.setIndex new THREE.BufferAttribute(idx, 1)
  return geom

# Concatenate SDF line geometries into one, applying to the three point
# attributes the model matrix given with each.  `parts` is [[geometry, Matrix4]],
# every geometry from makeSDFLineGeometry or makeSDFLinesGeometry; a null
# matrix copies straight through.  Segments are four vertices apiece in
# every source, so the index runs from the vertex count.
export mergeSDFGeometries = (THREE, parts) ->
  total = 0
  total += p[0].attributes.position.count for p in parts
  pos     = new Float32Array(total*3)
  endA    = new Float32Array(total*3)
  endB    = new Float32Array(total*3)
  corner  = new Float32Array(total*2)
  segDist = new Float32Array(total*2)
  nSeg    = total >> 2
  idx     = new (if total > 65535 then Uint32Array else Uint16Array)(nSeg*6)
  xf = (dst, src, m, at) ->
    e = m.elements
    for i in [0...src.length] by 3
      x = src[i] ; y = src[i+1] ; z = src[i+2]
      dst[at+i]   = e[0]*x + e[4]*y + e[8]*z  + e[12]
      dst[at+i+1] = e[1]*x + e[5]*y + e[9]*z  + e[13]
      dst[at+i+2] = e[2]*x + e[6]*y + e[10]*z + e[14]
    return
  at = 0
  for [g, m] in parts
    a = g.attributes
    n = a.position.count
    corner.set  a.corner.array,  at*2
    segDist.set a.segDist.array, at*2
    if m?
      xf pos,  a.position.array, m, at*3
      xf endA, a.endA.array,     m, at*3
      xf endB, a.endB.array,     m, at*3
    else
      pos.set  a.position.array, at*3
      endA.set a.endA.array,     at*3
      endB.set a.endB.array,     at*3
    at += n
  for s in [0...nSeg]
    idx.set [s*4, s*4+2, s*4+1,  s*4+2, s*4+3, s*4+1], s*6
  geom = new THREE.BufferGeometry()
  geom.setAttribute 'position', new THREE.BufferAttribute(pos, 3)
  geom.setAttribute 'endA',     new THREE.BufferAttribute(endA, 3)
  geom.setAttribute 'endB',     new THREE.BufferAttribute(endB, 3)
  geom.setAttribute 'corner',   new THREE.BufferAttribute(corner, 2)
  geom.setAttribute 'segDist',  new THREE.BufferAttribute(segDist, 2)
  geom.setIndex new THREE.BufferAttribute(idx, 1)
  return geom

# opt: color, opacity, widthPx (full stroke width, display px), aaPx (edge
# feather half-width, display px), dashSize/gapSize (world units; gapSize<=0
# means solid), resolution/pxRatio (pass shared uniform refs so one update
# reaches every material — note ShaderMaterial.clone() deep-copies uniforms,
# so re-point these on clones).
export makeSDFLineMaterial = (THREE, opt={}) ->
  uniforms =
    diffuse:     { value: new THREE.Color(opt.color ? 0xffffff) }
    opacity:     { value: opt.opacity ? 1.0 }
    halfWidthPx: { value: (opt.widthPx ? 2.0) / 2 }
    aaPx:        { value: opt.aaPx ? 1.0 }
    dashSize:    { value: opt.dashSize ? 1.0 }
    gapSize:     { value: opt.gapSize ? 0.0 }
  uniforms.resolution = opt.resolution ? { value: new THREE.Vector2(720, 720) }
  uniforms.pxRatio    = opt.pxRatio ? { value: 1.0 }
  mat = new THREE.ShaderMaterial {
    uniforms: uniforms
    vertexShader: SDF_VERT
    fragmentShader: SDF_FRAG
    transparent: true
    depthWrite: false      # AA fringe must not depth-block crossing lines
    side: THREE.DoubleSide
    # A quad's winding follows its segment's direction, so both faces are
    # drawn.  three.js splits a transparent DoubleSide material into a
    # BackSide and a FrontSide draw and sets material.needsUpdate before
    # each; forceSinglePass keeps it to one draw of a material shared by
    # every stroke of a colour.
    forceSinglePass: true
    clipping: true         # honor material.clippingPlanes (tape windows)
  }
  mat._color = opt.color
  return mat
