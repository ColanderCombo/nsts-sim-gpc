import {now as simNow} from '../../com/simRuntime.coffee'
import {Screen_AE_PFD} from 'meds/mdu/mduScreen_AE_PFD'

# ORBIT PRIMARY FLIGHT DISPLAY (ORB PFD)
#
# [1]   Off Flag – Indicates no updates from GPC. The ADI will freeze in
#       all axes if IMU data are missing (CF or DG bad), and needles will
#       be stowed (blanked), and ball static.
#
# [2]   Attitude ball – IMU based attitude. Reflects attitude defined by
#       ADI ATTITUDE switch.
#
# [3]   Rate Needles – IMU derived body rates in degrees/second. Reflects
#       scale selected by ADI Rate switch (see A/E PFD). Scale label is
#       located at the ends of each scale.
#
# [4]   Error Needles – Total attitude or DAP errors in degrees during
#       coast phases, depending on whether UNIV PTG Item 23 or 24 is
#       selected. During OMS and RCS burns, the errors displayed are
#       guidance command errors. During OMS burns, the errors reflect
#       errors in the OMS trim positions. During +X RCS burns, the error
#       is VGO thrust vector errors. The scale label is displayed in the
#       right (pitch) scale only and reflects the ADI Error switch
#       position (see A/E PFD).
#
# [5]   Digitals – Digital values of attitude displayed on the attitude
#       ball.
#
#       [JSC-48017/6-24]
#
# The instrument is the A/E PFD's ADI at the same place and size, alone on
# the display (JSC-48017 figures 6-8 and 6-24).
export class Screen_ORBIT_PFD extends Screen_AE_PFD
  screenName: 'ORBIT_PFD'
  parts: () -> ['adi']
