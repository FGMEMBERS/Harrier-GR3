# Things for auto-hover - currently we control
# /controls/engines/engine/throttle to maintain a particular height, or a
# particular ascent/descent rate.
#
# Our behaviour is controlled entirely by the /controls/flight/auto-hover
# property. Values are:
#
#   999 - Auto-hover off.
#
#     0 - Maintain fixed altitude (the current altitude at the time that
#     /controls/flight/auto-hover was set to 0).
#
#  Otherwise, /controls/flight/auto-hover is ascent rate in fps to be
#  maintained.
#
# fixme: The use of 999 to mean 'off' is a hack; perhaps we could use nil?
#

var window = screen.window.new(
        20,     # x
        100,    # y
        1,      # num of lines.
        9999,   # timeout
        );
window.bg = [0,0,0,.5]; # black alpha .5 background
# We'll use this window to show our status.

var auto_hover_prev = 999;
props.globals.setValue("/controls/flight/auto-hover", auto_hover_prev);
# Default to auto-hover off.

var autohover_ft2m = 12 * 2.54 / 100;   # feet to metres.
var auto_hover_m2ft = 100 / 2.54 / 12;  # metres to feet.
var auto_hover_lbs2kg = 0.45359237;     # pounds to kilogrammes.
# Some constants for conversion between imperial/metric.

var auto_hover_g = 9.81;
# Gravity in m/s/s.

var auto_hover_height_target = 0;
# Target height, only used if <auto_hover> is 0.

var auto_hover_mass_smoothed = 0;
# fixme: We calculate this from accelation and thrust, but it isn't actually
# used.

var auto_hover_t = 0.5;
# Interval in sec at which auto_hover_fn() is called.

var auto_hover_throttle_smoothed = 0;
# We use this smoothed throttle value to crudely model the slow response of the
# engine to throttle changes.

var auto_hover_fn = func {

    var auto_hover = props.globals.getValue("/controls/flight/auto-hover", 0);
    
    if (auto_hover == 999) {
        # Auto-hover is off, so nothing to do.
        
        if (auto_hover_prev != auto_hover) {
            # Stop auto-hover. Remove auto-hover status text.
            window.write("");
            # fixme: This leaves the window visible as a small grey
            # rectangle. Can we instead hide the window?
        }
    }
    else {
    
        var h_accel_g = props.globals.getValue("/accelerations/pilot-g");
        var h_accel = (h_accel_g - 0.988) * auto_hover_g;
        # Current vertical accelaration in m/s/s.
        #
        # For some reason /accelerations/pilot-g's stationary value is slightly
        # different from 1.0.  If we don't use the actual value here, we can
        # end up thinking we are accelarating slightly when we are not, leading
        # to us never quite reaching the target height.
        #
        # fixme: Perhaps use /accelerations/pilot-g on startup instead of
        # hard-coding the value here?
        
        var h_vel_fps = props.globals.getValue("/velocities/vertical-speed-fps");
        var h_vel = h_vel_fps * autohover_ft2m;
        # Current vertical speed in m/s.
        
        var h_ft = props.globals.getValue("/position/altitude-ft");
        var h = h_ft * autohover_ft2m;
        # Current height in metres.
        
        var thrust_lb = props.globals.getValue("/engines/engine/thrust-lbs", 0);
        var thrust = thrust_lb * auto_hover_lbs2kg * auto_hover_g;
        # Current engine thrust in Newtons. We assume this is pointed directly
        # downwards, but actually it's probably ok if this isn't the case -
        # we'll scale things automatically when we modify the throttle.
        
        var mass = 0;
        if (h_accel == 0) {
            mass = auto_hover_mass_smoothed;
        } else {
            mass = thrust / (auto_hover_g + h_accel);
        }
        # <mass> is calculated mass of aircraft. It isn't actually used in our
        # determination of the throttle setting.

        var throttle = props.globals.getValue("/controls/engines/engine/throttle");

        if (auto_hover != auto_hover_prev)
        {
            # We have changed to a new hover-mode.
            if (auto_hover == 0) {
                auto_hover_height_target = h;
                # Use current height has target.
                #window.write(sprintf("auto-hover: target height: %.1f ft", h_ft));
            }
            else {
                #window.write(sprintf("auto-hover: target vertical speed: %.1f fps", auto_hover));
            }
        }

        if (auto_hover_prev == 999) {
            # Starting auto-hover. Need to initialise smoothed variables to
            # current values:
            auto_hover_mass_smoothed = mass;
            auto_hover_throttle_smoothed = throttle;
        }

        var mass_smoothed_e = 0.1;
        auto_hover_mass_smoothed = auto_hover_mass_smoothed * (1-mass_smoothed_e) + mass * mass_smoothed_e;

        # Find target vertical speed:
        #
        if (auto_hover == 0) {
        
            # Calculate desired vertical speed by comparing target height and
            # current height.
            
            var h_vel_target_t = 3;
            # This is vaguely a time in seconds over which we will try to reach
            # target height.

            h_vel_target = (auto_hover_height_target - h) / h_vel_target_t;
            # Our target vertical speed. Approaches zero as we reach target
            # height.
            
            # Restrict vertical speed to avoid problems if we are a long way
            # from the target height.
            var h_vel_max_fps = 200;
            var h_vel_max = h_vel_max_fps * autohover_ft2m;
            if (h_vel_target > h_vel_max)   h_vel_target = h_vel_max;
            if (h_vel_target < -h_vel_max)  h_vel_target = -h_vel_max;
            
            window.write(
                    sprintf(
                            "auto-hover: height: target=%.1f ft actual=%.1f ft (%+.1f ft)",
                            auto_hover_height_target * auto_hover_m2ft,
                            h_ft,
                            h_ft - auto_hover_height_target * auto_hover_m2ft,
                            )
                    );
        }
        else
        {
            # Use target vertical speed directly.
            h_vel_target = auto_hover * autohover_ft2m;
            window.write(
                    sprintf(
                            "auto-hover: vertical speed: target=%.1f fps actual=%.1f fps (%+.1f fps)",
                            auto_hover,
                            h_vel_fps,
                            h_vel_fps - auto_hover,
                            )
                    );
        }

        # Decide on a target vertical accelaration to get us to the target
        # vertical speed.
        #
        # We know current accelaration and current thrust, and we know how
        # these are related (thrust - mass*g = mass*accel), and we assume
        # that thrust is proportional to throttle, so this will allow us to
        # adjust the throttle in an appropriate way.
        
        var h_accel_target_t = 8;
        # This is vaguely a time in seconds over which we will try to reach
        # the target velocity.

        var h_accel_target = (h_vel_target - h_vel) / h_accel_target_t;

        var thrust_target = thrust * (h_accel_target + auto_hover_g) / (h_accel + auto_hover_g);

        throttle_smoothed_e = 0.4;
        auto_hover_throttle_smoothed = auto_hover_throttle_smoothed * (1-throttle_smoothed_e) + throttle * throttle_smoothed_e;
        # We use a smoothed throttle value to crudely model the engine's slow
        # response to throttle changes.
        #
        # Would be nice to do this more accurately - e.g. maybe we could model
        # the engine by tracking the throttle over time, and calculate the
        # actual thrust over the period of time that the current vertical
        # accelaration was measured.

        throttle_target = thrust_target / thrust * auto_hover_throttle_smoothed;
        
        # Limit throttle to range 0..1.
        if (throttle_target < 0)    throttle_target = 0;
        if (throttle_target > 1)    throttle_target = 1;

        if (0) {
            # Detailed diagnostics.
            printf("auto_hover=%.1f: mass=%.1f mass_smoothed=%.1f height=[%.1f (%.1fft) target=%.1fm (%.1fft)] vel=[%.2f target=%.2f] accel=[%.2f target=%.2f] thrust=[%.1f target=%.1f] throttle=[%.1f target=%.1f]",
                    auto_hover,
                    mass,
                    auto_hover_mass_smoothed,
                    h,
                    h * auto_hover_m2ft,
                    auto_hover_height_target,
                    auto_hover_height_target * auto_hover_m2ft,
                    h_vel,
                    h_vel_target,
                    h_accel,
                    h_accel_target,
                    thrust,
                    thrust_target,
                    100*throttle,
                    100*throttle_target,
                    );
        }

        if (0) {
            # Brief diagnostics.
            if (auto_hover == 0) {
                printf("auto-hover: height: target=%.1f ft, actual=%.1f ft. vertical speed=%.2f fps.",
                        auto_hover_height_target * auto_hover_m2ft,
                        h * auto_hover_m2ft,
                        h_vel * auto_hover_m2ft,
                        );
            }
            else {
                printf("auto-hover: vertical speed: target=%.2f fps actual=%.2f fps.",
                        h_vel_target * auto_hover_m2ft,
                        h_vel * auto_hover_m2ft,
                        );
            }
        }

        # Update throttle:
        props.globals.setValue("/controls/engines/engine/throttle", throttle_target);
    }
    
    auto_hover_prev = auto_hover;
    settimer(auto_hover_fn, auto_hover_t);
}

settimer(auto_hover_fn, 0);
