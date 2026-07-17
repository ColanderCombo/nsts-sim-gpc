import * as THREE from 'three'
import {MDUScreen} from 'meds/mduScreen'

export class Screen_FILE_PATCH extends MDUScreen
  draw: () ->
    labels = [
      [ 4, 1,"ITEM A START ADDRESS"],
      [ 4, 2,"ITEM B DESIRED PATCH"],
      [33, 1, "ITEM C WRITE"],
      [ 4, 4,   "ADD ID    DESIRED  ACTUAL     ADD ID    DESIRED   ACTUAL"],
      # [ 0,31,"XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"]
      [ 4, 6,   "XXXXXX    XXXX     XXXX       XXXXXX    XXXX      XXXX"],
      [ 4, 7,   "XXXXXX    XXXX     XXXX       XXXXXX    XXXX      XXXX"],
      [ 4, 8,   "XXXXXX    XXXX     XXXX       XXXXXX    XXXX      XXXX"],
      [ 4, 9,   "XXXXXX    XXXX     XXXX       XXXXXX    XXXX      XXXX"],
      [ 4,10,   "XXXXXX    XXXX     XXXX       XXXXXX    XXXX      XXXX"],
      [ 4,11,   "XXXXXX    XXXX     XXXX       XXXXXX    XXXX      XXXX"],
      [ 4,12,   "XXXXXX    XXXX     XXXX       XXXXXX    XXXX      XXXX"],
      [ 4,13,   "XXXXXX    XXXX     XXXX       XXXXXX    XXXX      XXXX"],
      [ 4,14,   "XXXXXX    XXXX     XXXX       XXXXXX    XXXX      XXXX"],
      [ 4,15,   "XXXXXX    XXXX     XXXX       XXXXXX    XXXX      XXXX"],
      [ 4,16,   "XXXXXX    XXXX     XXXX       XXXXXX    XXXX      XXXX"],
      [ 4,17,   "XXXXXX    XXXX     XXXX       XXXXXX    XXXX      XXXX"],
      [ 4,18,   "XXXXXX    XXXX     XXXX       XXXXXX    XXXX      XXXX"],
      [ 1,22,"XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX0123456789"]
    ]

    @d.add [@d.line [[4,3], [50,3]], @d.c2h.white]
    for label in labels
      @d.add @d.strMEDS label[0], label[1], label[2], @d.c2h.white,scale=1.2,advance=0.82,scalex=0.85