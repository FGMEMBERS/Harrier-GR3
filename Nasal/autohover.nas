# Things for auto-hover.
#
# We control /controls/engines/engine/throttle to maintain height or
# ascent/descent rate, /controls/flight/elevator to maintain forward/backwards
# speed, /controls/flight/aileron to maintain sideways speed, and
# /controls/flight/rudder to control heading or rotation speed.
#
# By default, all quantities are in SI units.
#
# Our behaviour is controlled by the following properties:
#
#   /controls/auto-hover/y-target:
#       off - Auto-hover height control off.
#
#       current - Maintain fixed altitude (the current altitude at the time that
#       /controls/auto-hover/y-target was set to 'current').
#
#       Otherwise the target ascent rate in fps.
#
#   /controls/auto-hover/xz-mode
#       air speed       - Control horizontal speed relative to air.
#       ground speed    - Control horizontal speed relative to ground.
#
#   /controls/auto-hover/x-target
#       Target lateral speed (+ve to right) in knots, or 'off'.
#
#   /controls/auto-hover/z-target
#       Target forward speed in knots or 'off'.
#
#   /controls/auto-hover/rotation-target
#       Target rotation speed in degrees per sec, or 'current' to maintain
#       current heading, or 'off'.
#

var knots2si = 1852.0/3600;     # Knots to metres/sec.
var ft2si = 12 * 2.54 / 100;    # Feet to metres
var lbs2si = 0.45359237;        # Pounds to kilogrammes.
# Some constants for conversion between imperial/metric.

var gravity = 9.81; # Gravity in m/s/s.


var clip_abs = func(x, max) {
    if (x > max)    return max;
    if (x < -max)   return -max;
    return x;
}

var in_replay = func() {
    return props.globals.getValue('/sim/replay/replay-state') == 1;
}

# Returns true if there is weight on wheels.
#
var on_ground = func() {
    if (0
            or props.globals.getValue('/gear/gear/wow')
            or props.globals.getValue('/gear/gear[1]/wow')
            or props.globals.getValue('/gear/gear[2]/wow')
            or props.globals.getValue('/gear/gear[3]/wow')
            ) {
        return 1;
    }
    return 0;
}

var make_window = func(x, y) {
    var w = screen.window.new(
        x,
        y,
        1,      # num of lines.
        9999,   # timeout
        );
    w.bg = [0,0,0,.5]; # black alpha .5 background
    w.fg = [1, 1, 1, 0.5];
    # Setting font here doesn't appear to make any difference.
    w.font = getprop("/sim/gui/selected-style/fonts/message-display/name") or "HELVETICA_14";;
    w.fontsize = 8;
    return w;
}

# Returns text describing target vs actual.
var make_text = func(actual, target, units, fmt) {
    var target_text = sprintf(fmt, target);
    var actual_text = sprintf(fmt, actual);
    var delta_text = sprintf(fmt, actual - target);
    delta_text = string.trim(delta_text);
    c = left(delta_text, 1);
    if (c == '-') {
        delta_text = right(delta_text, size(delta_text) - 1);
    }
    else if ( c == '+') {
        delta_text = right(delta_text, size(delta_text) - 1);
    }
    else {
        c = '+';
    }
    #if (c != '-' and c != '+') {
    #    delta_text = '+' ~ delta_text;
    #    c = left(delta_text, 1);
    #}
    #t = sprintf('%s %s (%s%s %s)', actual_text, units, target_text, delta_text, units);
    t = sprintf('%s %s. (%s %s => %s %s)', target_text, units, c, delta_text, actual_text, units,);
    return t;
}

# An hack to allow us to modify behaviour at high speeds. Doesn't really work
# yet.
#
var speed_correction = func() {
    var s = props.globals.getValue('/velocities/equivalent-kt') * knots2si;
    s -= 70 * knots2si;
    if (s < 0) return 0;
    var sc = math.sqrt( s / (600*knots2si));
    return sc;
}

var auto_hover_aoa_nozzles_window       = make_window( 20, 175);
var auto_hover_xz_target_prime_window   = make_window( 20, 150);
var auto_hover_height_window            = make_window( 20, 125);
var auto_hover_z_window                 = make_window( 20, 100);
var auto_hover_x_window                 = make_window( 20, 75);
var auto_hover_rotation_window          = make_window( 20, 50);


props.globals.setValue('/controls/auto-hover/z-speed-error', 0);

var auto_hover_target_pos = nil;


# Sets property if it is currently nil. Useful to allow override from
# command-line with --prop:<name>=<value>.
#
var set_if_nil = func(name, value) {
    v = props.globals.getValue(name);
    if (v == nil) {
        props.globals.setValue(name, value);
    }
}

set_if_nil('/controls/auto-hover/z_offset', 6.58);
var get_auto_hover_z_offset = func() {
    return props.globals.getValue('/controls/auto-hover/z_offset');
}

#var auto_hover_z_offset = 6.58;
#auto_hover_z_offset = 0;
# Distance from aircraft origin (the tip of the boom) and midpoint between
# the two main wheels. Used to allows us to place wheel midpoint at target
# position.
#
# See Harrier-GR3.xml for offsets of two main gears - these are offsets x=-4.91
# and x=-8.25.
#
# [Why is aircraft fore/aft called 'z' in properties, but 'x' in model?]

# Class for setting a control (e.g. an elevator) whose derivitive (wrt to time)
# is proportional to third derivitive (wrt time) of a target value (typically a
# speed).
#
# Params:
#
#   name
#       Name to use inside property names.
#       We read/write various properties, such as:
#           /controls/auto-hover/<name>-mode
#           /controls/auto-hover/<name>-airground-mode
#           /controls/auto-hover/<name>-speed-target
#           /controls/auto-hover/<name>-speed-target-delta
#   name_user
#       Human-friendly name to use in diagnostics.
#   period
#       Delay in seconds between updates.
#   mode_name
#       Name of property that controls whether we use air speed or ground
#       speed. Typically modified by the user.
#   airspeed_get
#   groundspeed_get
#       Callables that returns the airspeed/groundspeed that we are trying to
#       control. This is a callable, rather than a property name, so that we
#       can be used with things that aren't available directly but must instead
#       be calculated, e.g. lateral airspeed.
#   control_name
#       Name of property that we modify in order to control the speed, e.g. the
#       elevator property.
#   speed_target_name
#       Name of property which is the target value for speed in knots or 'off';
#       this can be updated by the user.
#   control_smoothing
#       Sets the smoothing we apply to <control> to crudely model the delay in
#       it affecting <speed>.
#   t_deriv
#       Time in seconds over which we notionally expect our corrections to take
#       affect. This determines the size of changes to <control>.
#   window
#       We write status messages to this window.
#
# E.g. when hovering, forward speed is controlled by pitch. Forwards
# acceleration is roughly proportional to pitch angle (measured downward), and
# the derivitive of pitch angle (wrt time) is roughly proportional to elevator
# value.
#
# So if D foo is dfoo/ft:
#
#   D speed = pitch
#   D pitch = elevator - elevator0
#
# and:
#
#   DD speed = elevator - elevator0
#
# We don't know elevator0 (it's the neutral elevator position), so we
# differentiate again to get something we can implement:
#
#   DDD speed = D elevator
#
# For each iteration, we calculate the current DDD speed. And we also determine
# a target DDD speed, based on the target speed or accelaration, and use this
# to increment/decrement the elevator.
#
# There is usually a delay between changing the elevator and seeing the affect
# on pitch and then on accelaration. We model this by using a slightly smoothed
# and delayed 'effective elevator', determined by the <control_smoothing>
# param.
#
var auto_hover_speed = {
    new: func(
            name,
            name_user,
            period,
            airspeed_get,
            groundspeed_get,
            control_name,
            control_smoothing,
            t_deriv,
            window,
            debug=0,
            ) {
        var m = { parents:[auto_hover_speed]};
        
        m.name = name;
        m.name_user = name_user;
        m.period = period;
        m.airspeed_get = airspeed_get;
        m.groundspeed_get = groundspeed_get;
        m.control_name = control_name;
        m.control_smoothing = control_smoothing;
        m.t_deriv = t_deriv;
        m.window = window;
        m.debug = debug;
        
        m.speed_prev = 0;
        m.accel_target = 0;
        m.accel_prev = 0;
        me.on_ground = on_ground();
        
        m.mode_prev = 'off';
        set_if_nil(sprintf('/controls/auto-hover/%s-mode', m.name), m.mode_prev);
        set_if_nil(sprintf('/controls/auto-hover/%s-mode', m.name), m.mode_prev);
        set_if_nil(sprintf('/controls/auto-hover/%s-airground-mode', m.name), 'ground');
        set_if_nil(sprintf('/controls/auto-hover/%s-speed-target', m.name), '');
        set_if_nil(sprintf('/controls/auto-hover/%s-speed-target-delta', m.name), '');
        
        m.control = 0;
        m.control_smoothed = 0;
        
        # Schedule the first call to m.do().
        settimer( func { m.do()}, 0);
        
        return m;
    },
        
    do: func() {
        
        var mode = props.globals.getValue(sprintf('/controls/auto-hover/%s-mode', me.name));
        
        og = on_ground();
        if (me.on_ground and !og) {
            # Reset control if we've just left the ground.
            me.control_smoothed = 0;
        }
        
        if (og and !me.on_ground and mode != 'target') {
            # We have just landed; disable ourselves because auto-hover
            # horizontal speed control is really unhelpful after landing.
            mode = 'off';
            props.globals.setValue(sprintf('/controls/auto-hover/%s-mode', me.name), mode);
        }
        
        me.on_ground = og;
              
        if (mode == 'off' or mode == 'ground speed pid' or in_replay()) {
            # We are disabled.
            if (me.mode_prev != mode) {
                me.mode_prev = mode;
                me.window.close();
                props.globals.setValue(sprintf('/controls/auto-hover/%s-speed-target', me.name), '');
            }
            # Don't be called too frequently if we are disabled.
            settimer( func { me.do()}, 0.5);
            return;
        }
        
        # We are active.
        if (0 and me.debug) printf("me=%s mode=%s me.mode_prev=%s", me, mode, me.mode_prev);

        if (mode != me.mode_prev) {
            me.mode_prev = mode;
            me.speed_prev = nil;
            me.accel_prev = nil;
            me.control_smoothed = nil;
            if (on_ground()) {
                me.control_smoothed = 0;
            }
            
            # auto-hover AoA will disable (see Systems/Autopilot.xml) but we
            # need to turn off our AoA display explicitly here if it was previously active.
            auto_hover_aoa_nozzles_off();
        }

        var airground_mode = props.globals.getValue(sprintf('/controls/auto-hover/%s-airground-mode', me.name), 0);
        if (airground_mode == 'air')            speed = me.airspeed_get();
        else if (airground_mode == 'ground')    speed = me.groundspeed_get();
        else {
            printf('unrecognised airground_mode: %s', airground_mode);
            return;
        }
        
        var speed_target = props.globals.getValue(sprintf('/controls/auto-hover/%s-speed-target', me.name), 0);
        if (speed_target == nil or speed_target == '') {
            speed_target = speed;
            props.globals.setValue(sprintf('/controls/auto-hover/%s-speed-target', me.name), speed_target / knots2si);
        }
        
        if (mode == 'speed' or mode == 'target') {

            if (me.speed_prev == nil) {
                me.speed_prev = speed;
            }
            var accel = (speed - me.speed_prev) / me.period;

            if (me.accel_prev == nil)   me.accel_prev = accel;

            var daccel = (accel - me.accel_prev) / me.period;

            me.speed_prev = speed;
            me.accel_prev = accel;

            if (mode == 'target') {
                var target_lat = props.globals.getValue('/controls/auto-hover/xz-target-latitude');
                var target_lon = props.globals.getValue('/controls/auto-hover/xz-target-longitude');
                var pos_target = geo.Coord.new();
                pos_target.set_latlon(target_lat, target_lon);
                var pos_current = geo.aircraft_position();
                var target_bearing = pos_current.course_to( pos_target);
                var target_distance = pos_current.distance_to( pos_target);
                var aircraft_heading = props.globals.getValue('/orientation/heading-deg');
                var relative_bearing = target_bearing - aircraft_heading;
                var relative_bearing_rad = relative_bearing * math.pi / 180;
                
                # Find target distance relative to the direction we are
                # controlling. I think this may be slightly wrong - sometimes
                # the distance increases even though our actual speed is
                # in the correct direction; maybe we need to factor in the
                # the attitude to convert our speed into strict horizontal
                # direction to match our target?
                #
                if (me.name == 'z') {
                    # We are controlling forewards speed.
                    target_distance = target_distance * math.cos(relative_bearing_rad);
                    
                    # Aircraft origin is tip of front boom. Correct so that
                    # we aim to place the target halfway between the two
                    # main gears.
                    target_distance += get_auto_hover_z_offset();
                }
                else if (me.name == 'x') {
                    # We are controlling sideways speed. 
                    target_distance = target_distance * math.sin(relative_bearing_rad);
                }
                else {
                    printf('*** unrecognised me.name=%s', me.name);
                    return;
                }
                var t_distance = 22.0;
                var speed_target = target_distance / t_distance;
                
                var speed_max = 30 * knots2si;
                if (me.name == 'x')         speed_max = 20 * knots2si;
                else if (speed_target < 0)  speed_max = 20 * knots2si;
                speed_target = clip_abs(speed_target, speed_max);
                
                var speed_target_kts = speed_target / knots2si;
                var accel_target = (speed_target - speed) / me.t_deriv;
                
                if (math.sgn(accel_target) != math.sgn(target_distance) and target_distance != 0) {
                    # If we are deaccelarating, target a constant accel that
                    # would bring us stationary at the target position. This
                    # appears to work better than trying to track speed_target.
                    accel_target = -speed*speed / 2 / target_distance;  
                    #printf('fixing accel_target=%.2f', accel_target);
                }
                
                if (0) {
                    printf('target=%s,%s target_bearing=%.1f target_distance=%.1f aircraft_heading=%.1f relative_bearing=%.1f speed_target=%s kts',
                            target_lat,
                            target_lon,
                            target_bearing,
                            target_distance,
                            aircraft_heading,
                            relative_bearing,
                            speed_target_kts,
                            );
                }
            }
            else {

                var speed_target_kts = props.globals.getValue(sprintf('/controls/auto-hover/%s-speed-target', me.name), 0);
                if (speed_target_kts == '') {
                    # No target speed set, so use current speed.
                    speed_target_kts = speed / knots2si;
                }

                var speed_target_delta = props.globals.getValue(sprintf('/controls/auto-hover/%s-speed-target-delta', me.name), 0);
                if (speed_target_delta != '') {
                    # Alter target speed.
                    #
                    # We round to multiple of 0.5 for convenience.
                    speed_target_kts += speed_target_delta;
                    speed_target_kts = math.round(speed_target_kts, 0.5);
                    props.globals.setValue(sprintf('/controls/auto-hover/%s-speed-target-delta', me.name), '');
                    props.globals.setValue(sprintf('/controls/auto-hover/%s-speed-target', me.name), speed_target_kts);
                }

                var speed_target = speed_target_kts * knots2si;
                var accel_target = (speed_target - speed) / me.t_deriv;
            }

            if (1) {

                # Don't try to accelerate too much - can end up over-pitching.
                var accel_target_max = 0.5 + 0.1 * math.sqrt(abs(speed));
                accel_target = clip_abs(accel_target, accel_target_max);
                var text = sprintf('auto-hover: %s:', me.name_user);
                var highlight = 0;
                if (mode == 'target') {
                    text = sprintf('%s %.1f m.', text, target_distance);
                    if (auto_hover_xz_target_recent_change > 0) {
                        # Next line makes us flashe the new value, but looks a bit clunky.
                        #highlight = math.mod( math.round(auto_hover_xz_target_recent_change / 2), 2);
                        highlight = 1;
                        if (me.name == 'x') {
                            auto_hover_xz_target_recent_change -= 1;
                        }
                    }
                }
                text = sprintf(
                        '%s %s',
                        text,
                        make_text(speed / knots2si, speed_target_kts, 'kts', '%+.2f'),
                        );
                if (highlight) {
                    fg = me.window.fg;
                    me.window.fg = [1, 0, 0, 0.5];
                    me.window.write(text);
                    me.window.fg = fg;
                }
                else {
                    me.window.write(text);
                }
            }

            # Set daccel_target by looking at accel target vs actual, using
            # me.t_deriv to scale.
            var daccel_target = (accel_target - accel) / me.t_deriv;

            var e = me.control_smoothing;
            var correction = speed_correction();
            var daccel_max = 2 * (1 - correction);
            daccel_target = daccel_target * (1 - correction);
            e = e + ( (1-e) * correction);
            daccel_target= clip_abs(daccel_target, daccel_max);
            if (me.control_smoothed == nil) {
                me.control = props.globals.getValue(me.control_name, 0);
                me.control_smoothed = me.control;
            }
            
            var control_actual = props.globals.getValue(me.control_name);
            me.control_smoothed = (1-e) * me.control_smoothed + 0 * e * me.control + e * control_actual;

            # Derivitive of <control> is proportional to <daccel_target>. We
            # assume that <me.t_deriv> has scaled things; though might be
            # better to use daccel_target * me.period here?
            var control_new = me.control_smoothed + daccel_target;

            if (me.debug) {
                printf(
                        'speed: %+.5f target=%+.5f. accel: %+.5f target=%+.5f max=.%+.5f daccel: %+.5f target=%+.5f. control: raw=%+.5f smoothed=%+.5f => new=%+.5f',
                        speed,
                        speed_target,
                        accel,
                        accel_target,
                        accel_target_max,
                        daccel,
                        daccel_target,
                        me.control,
                        me.control_smoothed,
                        control_new,
                        );
            }

            if (!on_ground()) {
                me.control = control_new;
                props.globals.setValue(me.control_name, me.control);
            }
            # We store the control setting in our state so that we overwrite
            # any changes by the user.
        }
        
        settimer( func { me.do()}, me.period);
    },
};


var z_speed = nil;
if (z_speed == nil) {
z_speed = auto_hover_speed.new(
        name: 'z',
        name_user: 'forwards',
        period: 0.1,
        airspeed_get: func () {
            # Forwards air-speed.
            return props.globals.getValue('/velocities/equivalent-kt') * knots2si;
        },
        groundspeed_get: func () {
            # We return the forwards ground-speed. Note that uBody-fps is
            # speed along longitudal axis of aircraft, which is different from
            # forwards ground speed if attitude is not zero deg.
            var w = props.globals.getValue('/velocities/wBody-fps');
            var u = props.globals.getValue('/velocities/uBody-fps');
            var attitude_deg = props.globals.getValue('/orientation/pitch-deg');
            var attitude = attitude_deg * math.pi / 180;
            var ret = u * math.cos(attitude) + w * math.sin(attitude);
            return ret * ft2si;
        },
        control_name: '/controls/flight/elevator',
        control_smoothing: 0.015,
        t_deriv: 3.5,
        window: auto_hover_z_window,
        debug: 0,
        );
}
# There are a few properties that look like they give us
# the airspeed, but they don't all behave as we want.
# /instrumentation/airspeed-indicator/indicated-speed-kt seems to jump
# every few seconds. /velocities/airspeed-kt doesn't go negative when we go
# backwards.
#
# /velocities/equivalent-kt seems to behave ok

var x_speed = auto_hover_speed.new(
        name: 'x',
        name_user: 'sideways',
        period: 0.1,
        airspeed_get: func () {
            # Lateral (+ve to right) air-speed.
            var z_speed_kt = props.globals.getValue('/velocities/equivalent-kt', 0);
            var z_speed = z_speed_kt * knots2si;
            var angle = props.globals.getValue('/orientation/side-slip-rad');
            var x_speed = z_speed * math.tan(angle);
            if (0) printf('z_speed=%.1f kt; angle=%.1f deg; returning x_speed=%.1f',
                    z_speed,
                    angle * 180 / math.pi,
                    x_speed,
                    );
            return x_speed;
        },
        groundspeed_get: func () {
            # Lateral (+ve to right) ground-speed.
            #return vbody_smooth();
            return props.globals.getValue('/velocities/vBody-fps') * ft2si;
        },
        control_name: '/controls/flight/aileron',
        speed_target_name: '/controls/auto-hover/x-target',
        control_smoothing: 0.015,
        t_deriv: 3.5,
        window: auto_hover_x_window,
        );
# There doesn't appear to be a property for lateral airspeed, so we calculate
# it from forward airspeed and side-slip angle.




# Class for handling rudder when hovering.
#
# As of 2019-01-09 this is unused - we have an implementation that uses fg's
# autopilot support.
#
# Params:
#   name
#       Name to use on screen.
#   period
#       Delay in seconds between updates.
#   speed_get
#       Function which returns rotation speed in degrees per second.
#   heading_get
#       Function which returns current heading in degrees.
#   control_name
#       Name of property that we modify in order to control rotation/heading,
#       e.g. the rudder property.
#   target_name
#       Name of property whose value is the target value for rotation speed in
#       degrees per second, or 'off' if we are to do nothing, or 'current' if
#       we should target the current heading.
#   control_smoothing
#       Sets the smoothing we apply to <control> to crudely model the delay in
#       it affecting <speed>.
#   t_deriv
#       Time in seconds over which we notionally expect our corrections to take
#       affect. This determines the size of changes to <control>.
#   window
#       We write status messages to this window.
#   debug
#       If true, we output extra diagnostics.
#
var auto_hover_rotation = {
    new: func(
            name,
            period,
            mode_name,
            speed_get,
            heading_get,
            control_name,
            target_name,
            control_smoothing,
            t_deriv,
            window,
            debug=0,
            ) {
        var m = { parents:[auto_hover_rotation]};
        
        m.name = name;
        m.period = period;
        m.mode_name = mode_name;
        m.speed_get = speed_get;
        m.heading_get = heading_get;
        m.control_name = control_name;
        m.target_name = target_name;
        m.control_smoothing = control_smoothing;
        m.t_deriv = t_deriv;
        m.window = window;
        m.debug = debug;
        
        m.mode_prev = '';
        m.speed_prev = 0;
        m.accel_target = 0;
        m.accel_prev = 0;
        
        m.target_prev = 'off';
        props.globals.setValue(m.target_name, m.target_prev);
        
        m.control = 0;
        m.control_smoothed = 0;
        
        # Schedule the first call to m.do().
        settimer( func { m.do()}, 0);
        
        return m;
    },
        
    do: func() {
        var active = 1;
        var mode = props.globals.getValue(me.mode_name, 0);
        
        if (in_replay()) {
            active = 0;
        }
        else if (mode == 'speed pid' or mode == 'heading pid') {
        }
        else if (mode == nil or mode == '') {
            active = 0;
            if (me.mode_prev != mode) {
                me.window.close();
            }
        }
        else {
            if (mode == 'speed') {
                var speed_target = props.globals.getValue('/controls/auto-hover/rotation-speed-target', 0);
                if (me.mode_prev != mode) {
                    # Starting from scratch; preset some state appropriately.
                    me.control = props.globals.getValue(me.control_name, 0);
                    me.control_smoothed = me.control;
                }
            }
            else if (mode == 'heading') {
                var heading_target = props.globals.getValue('/controls/auto-hover/rotation-heading-target', 0);
                var heading = me.heading_get();
                var speed_target = (heading_target - heading) / me.t_deriv;
            }
            else {
                printf('unrecognised mode: %s', mode);
                return;
            }

            # Figure out how to get to speed_target.
            var speed = me.speed_get();
            var accel = (speed - me.speed_prev) / me.period;

            me.speed_prev = speed;
            me.accel_prev = accel;

            var accel_target = (speed_target - speed) / me.t_deriv;

            # Don't try to accelerate too much - can end up unstable.
            var accel_target_max = 0.2;
            
            var correction = speed_correction();
            accel_target_max = 0.2 * (1 - correction);
            
            accel_target = clip_abs(accel_target, accel_target_max);
            var text = sprintf('auto-hover: %s:', me.name);
            if (mode == 'heading') {
                text = sprintf(
                        '%s %s',
                        text,
                        make_text(heading, heading_target, 'deg', '%.1f'),
                        );
            }
            else {
                text = sprintf(
                        '%s %s',
                        text,
                        make_text(speed, speed_target, 'deg/s', '%+.1f'),
                        );
            }
            me.window.write(text);

            var e = me.control_smoothing;
            e = e + (1-e) * correction;
            var control_actual = props.globals.getValue(me.control_name);
            me.control_smoothed = (1-e) * me.control_smoothed + 0 * e * me.control + e * control_actual;

            var control_new = me.control_smoothed + accel_target;

            if (me.debug) {
                printf(
                        'speed: %+.5f target=%+.5f. accel: %+.5f target=%+.5f. control: raw=%+.5f smoothed=%+.5f => new=%+.5f',
                        speed,
                        speed_target,
                        accel,
                        accel_target,
                        me.control,
                        me.control_smoothed,
                        control_new,
                        );
            }

            if (!on_ground()) {
                me.control = control_new;
                props.globals.setValue(me.control_name, me.control);
                # We store the control setting here so that we can overwrite any
                # changes by the user.
            }
        }
        
        me.mode_prev = mode;
        
        if (active) settimer( func { me.do()}, me.period);
        else {
            settimer( func { me.do()}, 0.5);
            #printf('inactive: rotation');
        }
    },
};


var auto_hover_rotation = auto_hover_rotation.new(
        name: 'heading',
        period: 0.1,
        mode_name: '/controls/auto-hover/rotation-mode',
        speed_get: func () {
            return props.globals.getValue('orientation/yaw-rate-degps', 0);
        },
        heading_get: func() {
            return props.globals.getValue('orientation/heading-deg', 0);
        },
        control_name: '/controls/flight/rudder',
        target_name: '/controls/auto-hover/rotation-speed-target',
        control_smoothing: 0.015,
        t_deriv: 3.5,
        window: auto_hover_rotation_window,
        debug: 0,
        );

var auto_hover_rotation_current_heading = func() {
    props.globals.setValue(
            '/controls/auto-hover/rotation-heading-target',
            props.globals.getValue('orientation/heading-deg', 0),
            );
    props.globals.setValue('/controls/auto-hover/rotation-mode', 'heading');
}
var auto_hover_rotation_current_heading_pid = func() {
    props.globals.setValue(
            '/controls/auto-hover/rotation-heading-target',
            props.globals.getValue('orientation/heading-deg', 0),
            );
    props.globals.setValue('/controls/auto-hover/rotation-mode', 'heading pid');
}
var auto_hover_rotation_change = func(delta) {
    var mode = props.globals.getValue('/controls/auto-hover/rotation-mode', 0);
    var speed_target = 0;
    if (mode == 'speed' or mode == 'speed pid') {
        speed_target = props.globals.getValue('/controls/auto-hover/rotation-speed-target', 0);
        if (speed_target == nil)    speed_target = 0;
    }
    else {
        if (mode == 'heading pid')  mode = 'speed pid';
        else    mode = 'speed';
        props.globals.setValue('/controls/auto-hover/rotation-mode', mode);
        props.globals.setValue('/controls/auto-hover/rotation-heading-target', '');
    }
    speed_target += delta;
    props.globals.setValue('/controls/auto-hover/rotation-speed-target', speed_target);
}

var auto_hover_rotation_off = func() {
    props.globals.setValue('/controls/auto-hover/rotation-mode', '');
    props.globals.setValue('/controls/flight/rudder', 0);
}

# Class for controlling height when hovering.
#
# Params:
#
#   period:
#       Delay in seconds between updates.
#   mode_name
#       Name of property that controls operation. This property's value is
#       typically modified by user keypresses.
#
#       Values:
#           off     - We do nothing.
#           current - Maintain current height.
#           Otherwise target ascent rate in feet per second.
#   window
#       We write status messages to this window.
#
var auto_hover_height = {
    new: func(
            period,
            mode_name,
            window,
            ) {
        var m = { parents:[auto_hover_height]};
        m.it = 0;
        m.critical_active = 0;
        m.period = period;
        m.mode_name = mode_name;
        m.window = window;
        
        m.mode_prev = 'off';
        set_if_nil(m.mode_name, m.mode_prev);
        
        # Schedule the first call to m.do().
        settimer( func { m.do()}, 0);
        
        return m;
    },
    
    do: func () {
    
        var mode = props.globals.getValue(me.mode_name);
        
        if (mode == 'off' or in_replay()) {
            if (me.mode_prev != mode)   me.window.close();
            settimer( func { me.do()}, 0.5);
            return;
        }
        
        else {
        
            me.it += 1;

            var accel_fpss = -1 * props.globals.getValue('/accelerations/ned/down-accel-fps_sec');
            var accel = accel_fpss * ft2si;

            var speed_fps = props.globals.getValue('/velocities/vertical-speed-fps');
            var speed = speed_fps * ft2si;
            # Current vertical speed in m/s.

            var height_ft = props.globals.getValue('/position/altitude-ft');
            var height = height_ft * ft2si;
            # Current height in metres.

            var thrust_lb = props.globals.getValue('/engines/engine/thrust-lbs', 0);
            var thrust = thrust_lb * lbs2si * gravity;
            # Current engine thrust in Newtons. We assume this is pointed directly
            # downwards, but actually it's probably ok if this isn't the case -
            # we'll scale things automatically when we modify the throttle.

            var throttle = props.globals.getValue('/controls/engines/engine/throttle');

            var speed_target = nil;
            var height_target = nil;
            
            #if (mode != me.mode_prev)
            #{
            #    # We have changed to a new hover-mode.
            #    if (mode == 'current') {
            #        #me.height_target = height;
            #        #props.globals.setValue('/controls/auto-hover/y-target-height', height);
            #        # Use current height as target.
            #        #window.write(sprintf('auto-hover: target height: %.1f ft', height_ft));
            #    }
            #    else {
            #        props.globals.setValue(me.mode_name, 'speed');
            #        #window.write(sprintf('auto-hover: target vertical speed: %.1f fps', auto_hover));
            #    }
            #}

            if (me.mode_prev == 'off') {
                # Starting auto-hover. Need to initialise smoothed variables to
                # current values:
                me.throttle_smoothed = throttle;
                me.accel_max_smoothed = nil;
            }

            # Find target vertical speed:
            #
            if (mode == 'height') {

                # Calculate desired vertical speed by comparing target height and
                # current height.

                var t = 3;
                # This is vaguely a time in seconds over which we will try to reach
                # target height.

                var height_target_ft = props.globals.getValue('/controls/auto-hover/y-height');
                height_target = height_target_ft * ft2si;
                speed_target = (height_target - height) / t;
                # Our target vertical speed. Approaches zero as we reach target
                # height.

                # Restrict vertical speed to avoid problems if we are a long way
                # from the target height.
                var speed_max_fps = 200;
                var speed_max = speed_max_fps * ft2si;
                if (speed_target > speed_max)   speed_target = speed_max;
                if (speed_target < -speed_max)  speed_target = -speed_max;

                me.window.write(
                        sprintf(
                                'auto-hover: vertical: %s',
                                make_text(height_ft, height_target / ft2si, 'ft', '%.2f'),
                                )
                        );
            }
            else
            {
                # Use target vertical speed directly.
                var speed_target_fps = props.globals.getValue('/controls/auto-hover/y-speed');
                if (speed_target_fps != nil) {
                    speed_target = speed_target_fps * ft2si;
                }
            }

            # Decide on a target vertical acceleration to get us to the target
            # vertical speed.
            #
            # We know current acceleration and current thrust, and we know how
            # these are related (thrust - mass*g = mass*accel), and we assume
            # that thrust is proportional to throttle, so this will allow us to
            # adjust the throttle in an appropriate way.

            var t = 8;
            # This is vaguely a time in seconds over which we will try to reach
            # the target speed.

            var accel_target = (speed_target - speed) / t;

            var throttle_smoothed_e = 0.4;
            me.throttle_smoothed = me.throttle_smoothed * (1-throttle_smoothed_e) + throttle * throttle_smoothed_e;
            #
            # We use a smoothed throttle value to crudely model the engine's slow
            # response to throttle changes.
            #
            # Would be nice to do this more accurately - e.g. maybe we could
            # model the engine by tracking the throttle over time, and
            # calculate the effective average thrust over the period of time
            # that the current vertical acceleration was measured.

            var override_text_1 = '';
            var height_above_ground = props.globals.getValue('/position/gear-agl-m');
            
            if (speed >= -7*ft2si and speed_target > -6*ft2si) {
                #printf( 'doing nothing because speed=%.2f fps', speed/ft2si);
            }
            else if (speed < 0 and throttle >= 0.1 and accel != -gravity and height_above_ground > 0) {
            
                # See whether we need to override accel_target to avoid
                # crashing into ground.
                #
                # We don't bother to try to correct for vertical air
                # resistence, though this means we may slightly overestimate
                # the maximum deaccelaration we can achieve.
                
                
                # Look at height a couple of seconds from now, to crudely
                # correct for engine response time.
                var height_above_ground2 = height_above_ground + speed * 2;
                if (height_above_ground2 < 0)   height_above_ground2 = 1;

                var speed_slow = -2 * ft2si;
                
                var speed2 = speed;
                var speed3 = speed + 3 * accel;
                if (speed3 < speed2)    speed2 = speed3;

                accel_critical = (speed2*speed2 - speed_slow*speed_slow) / 2 / height_above_ground2;
                # This is the constant accelaration that would give a
                # smooth landing, given our current height and vertical
                # speed.

                var thrust_max = thrust * 1.0 / me.throttle_smoothed;
                # Thrust seems to be exactly proportional to throttle.
                
                var air_resistance = 82 * -speed;
                # Not sure this is significant.

                var mass = (thrust + air_resistance) / (gravity + accel);
                accel_max = thrust_max / mass - gravity;
                # This is the maximum vertical acceleration that we can achieve.
                #
                # Unfortunately this isn't an accurate or stable measure. Maybe
                # we need to take vertical air resistance into account?

                # Our calculation for accel_max is noisy, so we smooth it
                # here. In theory it should be stable, changing only as fuel
                # load decreases and/or engine power is affected by altitude.
                var accel_max_smoothed_e = 0.1;
                if (me.accel_max_smoothed == nil) {
                    me.accel_max_smoothed = accel_max;
                }
                else {
                    me.accel_max_smoothed = me.accel_max_smoothed * (1-accel_max_smoothed_e)
                            + accel_max*accel_max_smoothed_e;
                }
                
                var safety_hack = 0.5;
                var agl_hack = 50*ft2si;

                var speed_critical = speed_target;
                if (me.accel_max_smoothed > 0) {
                    speed_critical = -math.sqrt( 2 * me.accel_max_smoothed*safety_hack * height_above_ground);
                }
                # speed_critical is speed we would be doing at this altitude in
                # perfect fast descent.

                var override = 0;
                if (accel_critical > me.accel_max_smoothed * safety_hack) {
                    #printf('accel_critical > me.accel_max_smoothed * safety_hack');
                    override = 1;
                    me.critical_active = me.it;
                }
                else if (speed2 < speed_critical*0.75) {
                    #printf('speed2 < speed_critical*0.75');
                    override = 1;
                    me.critical_active = me.it;
                }
                else if (speed2 < speed_critical*0.5 and height_above_ground/ft2si < 100) {
                    #printf('speed2 < speed_critical*0.5 and height_above_ground/ft2si < 100');
                    override = 1;
                    me.critical_active = me.it;
                }
                else if (height_above_ground < agl_hack and speed_target < 2*speed_slow) {
                    #printf('height_above_ground < agl_hack and speed_target < 2*speed_slow');
                    override = 1;
                    me.critical_active = me.it;
                }
                else if (me.critical_active and me.it < me.critical_active + 5/me.period) {
                    #printf('continuity');
                    override = 1;
                }
                else {
                    me.critical_active = 0;
                }

                if (override) {
                    # We need to override accel_target, because vertical
                    # acceleration required is near the maximum we can do.
                    accel_target = accel_critical;

                    # Increment accel_target a little if it's a lot bigger
                    # than the existing accel, to crudely compensate for
                    # the delay in large changes to throttle.
                    if (accel_target > accel) {
                        accel_target = accel_target + 2 * (accel_target - accel);
                    }

                    override_text_1 = ' * override *';

                    if (height_above_ground < agl_hack and speed2 >= speed_slow*2) {
                        # Switch mode to maintain current height when we are
                        # slow and near ground.
                        #
                        # [Trying to land causes problems - we tend to bounce
                        # and get unstable (unless we kill the engine, but not
                        # sure we should automate that).
                        #
                        props.globals.setValue(me.mode_name, 'height');
                        props.globals.setValue('/controls/auto-hover/y-height', height_ft);
                        
                        # Reset target vertical speed to zero in case user
                        # re-enables it.
                        props.globals.setValue('/controls/auto-hover/y-speed', 0);
                        override_text_1 = ' #';
                    }
                }

                if (0) {
                    # Detailed diagnostics about override.
                    #
                    var override_text_2 = sprintf(
                            '%s override it=%s agl=%.1f ft speed=[%.1f fps 2=%.1f fps critical=%.1f fps] fps throttle=[%.2f smoothed=%.2f] thrust=[%.1f max=%.1f] air_resistance=%.1f mass=%.1f kg accel=[%.2f fps/s critical=%.2f fps/s max=%.2f fps/s target=%.2f fps/s]',
                            override_text_1,
                            me.it,
                            height_above_ground / ft2si,
                            speed / ft2si,
                            speed2 / ft2si,
                            speed_critical / ft2si,
                            throttle,
                            me.throttle_smoothed,
                            thrust,
                            thrust_max,
                            air_resistance,
                            mass,
                            accel / ft2si,
                            accel_critical / ft2si,
                            me.accel_max_smoothed / ft2si,
                            accel_target / ft2si,
                            );
                    printf( "%s", override_text_2);
                }
            }
            
            var thrust_target = thrust * (accel_target + gravity) / (accel + gravity);
            
            var throttle_target = 0;
            if (me.throttle_smoothed == 0 and thrust_target > thrust) {
                # This is a hack to ensure we can increase thrust if it is
                # currently zero.
                throttle_target = thrust_target / thrust * 0.1;
            }
            else {
                throttle_target = thrust_target / thrust * me.throttle_smoothed;
            }
            
            # Limit throttle to range 0..1.
            if (throttle_target < 0)    throttle_target = 0;
            if (throttle_target > 1)    throttle_target = 1;

            if (0) {
                # Detailed diagnostics.
                height_target = -1;
                printf('auto-hover height mode=%.1f: height=[%.1f (%.1fft) target=%.1fm (%.1fft)] vel=[%.2f target=%.2f] accel=[%.2f target=%.2f] throttle=[%.2f smoothed=%.2f] thrust=[%.1f target=%.1f] throttle=[%.1f target=%.1f]',
                        mode,
                        height,
                        height / ft2si,
                        height_target,
                        height_target / ft2si,
                        speed,
                        speed_target,
                        accel,
                        accel_target,
                        throttle,
                        me.throttle_smoothed,
                        thrust,
                        thrust_target,
                        100*throttle,
                        100*throttle_target,
                        );
            }

            if (0) {
                # Brief diagnostics.
                if (auto_hover == 0) {
                    printf('auto-hover: height: target=%.1f ft, actual=%.1f ft. vertical speed=%.2f fps.',
                            height_target / ft2si,
                            height / ft2si,
                            speed / ft2si,
                            );
                }
                else {
                    printf('auto-hover: vertical speed: target=%.2f fps actual=%.2f fps.',
                            speed_target / ft2si,
                            speed / ft2si,
                            );
                }
            }

            # Update throttle:
            
            if ( !on_ground()) {
                props.globals.setValue('/controls/engines/engine/throttle', throttle_target);
            }
            
            if (mode == 'speed') {
                if (override_text_1 != '') {
                    override_text_1 = sprintf('%s throttle=%.2f speed_critical=%.1f fps',
                            override_text_1,
                            throttle_target,
                            speed_critical / ft2si,
                            );
                }
                me.window.write(
                        sprintf(
                                'auto-hover: vertical: %s%s',
                                make_text(speed_fps, speed_target / ft2si, 'fps', '%+.2f'),
                                override_text_1,
                                )
                        );
            }

        }

        me.mode_prev = mode;
        
        settimer( func { me.do()}, me.period);
    },
};

var height = auto_hover_height.new(
        period: 0.25,
        mode_name: '/controls/auto-hover/y-mode',
        window: auto_hover_height_window,
        );

var auto_hover_y_current = func() {
    var height_ft = props.globals.getValue('/position/altitude-ft');
    props.globals.setValue('/controls/auto-hover/y-height', height_ft);
    props.globals.setValue('/controls/auto-hover/y-mode', 'height');
}

var auto_hover_y_speed_set = func(speed) {
    props.globals.setValue('/controls/auto-hover/y-speed', speed);
    props.globals.setValue('/controls/auto-hover/y-mode', 'speed');
}

var auto_hover_y_speed_delta = func(delta) {
    if (props.globals.getValue('/controls/auto-hover/y-mode') == 'speed') {
        speed = props.globals.getValue('/controls/auto-hover/y-speed');
        if (speed == nil)   speed = 0;
    }
    else {
        props.globals.setValue('/controls/auto-hover/y-mode', 'speed');
        speed = 0;
    }
    speed += delta;
    props.globals.setValue('/controls/auto-hover/y-speed', speed);
}

var auto_hover_y_off = func() {
    props.globals.setValue('/controls/auto-hover/y-mode', 'off');
}



var auto_hover_aoa_nozzles_change = func(delta) {
    target = props.globals.getValue('/controls/auto-hover/aoa-nozzles-target');
    if (target == nil) {
        target = props.globals.getValue('/orientation/alpha-deg');
        target = math.round(target, 0.5);
    }
    target = target + delta;
    props.globals.setValue('/controls/auto-hover/aoa-nozzles-target', target);
    text = sprintf('auto-hover aoa nozzles: target=%.1f', target);
    auto_hover_aoa_nozzles_window.write(text);
}

var auto_hover_aoa_nozzles_off = func() {
    props.globals.getNode('/controls/auto-hover/aoa-nozzles-target').clearValue();
    auto_hover_aoa_nozzles_window.close();
}

var auto_hover_xz_target_lat_old = nil;
var auto_hover_xz_target_lon_old = nil;
var auto_hover_xz_target_recent_change = 0;
props.globals.setValue('/controls/auto-hover/xz-target', '');


# Handles Alt-, so that next click sets target position. We cancel if Alt-, is
# pressed twice.
var auto_hover_xz_target_click = func() {
    var xz_target = props.globals.getValue('/controls/auto-hover/xz-target', 0);
    if (xz_target == 'prime' or xz_target == 'prime-2') {
        # Cancel.
        props.globals.setValue('/controls/auto-hover/xz-target', '');
        auto_hover_xz_target_prime_window.close();
    }
    else {
        props.globals.setValue('/controls/auto-hover/xz-target', 'prime');
        auto_hover_xz_target_prime_window.write('auto-hover: horizontal: next click sets target position...');
    }
}


# This function sets up target position in response to clicks on scenery.
#
var auto_hover_xz_target = func() {
    var xz_target = props.globals.getValue('/controls/auto-hover/xz-target', 0);
    #printf('xz_target=%s', xz_target);
    if (xz_target == 'prime') {
        var pos = geo.click_position();
        if (pos != nil) {
            auto_hover_xz_target_lat_old = pos.lat();
            auto_hover_xz_target_lon_old = pos.lon();
        }
        props.globals.setValue('/controls/auto-hover/xz-target', 'prime-2');
    }
    else {
        var pos = nil;
        
        if (xz_target == 'prime-2') {
            pos = geo.click_position();
            if (pos != nil
                    and pos.lat() == auto_hover_xz_target_lat_old
                    and pos.lon() == auto_hover_xz_target_lon_old
                    ) {
                pos = nil;
            }
        }
        else if (xz_target == 'current') {
            var pos = geo.aircraft_position();
            var aircraft_heading = props.globals.getValue('/orientation/heading-deg');
            # Use midpoint between the main gears:
            pos.apply_course_distance( aircraft_heading, -get_auto_hover_z_offset());
        }
        
        if (pos != nil) {
            auto_hover_xz_target_lat_old = pos.lat();
            auto_hover_xz_target_lon_old = pos.lon();
            props.globals.setValue('/controls/auto-hover/xz-target', '');
            props.globals.setValue('/controls/auto-hover/xz-target-latitude', pos.lat());
            props.globals.setValue('/controls/auto-hover/xz-target-longitude', pos.lon());
            props.globals.setValue('/controls/auto-hover/x-mode', 'target');
            props.globals.setValue('/controls/auto-hover/z-mode', 'target');
            auto_hover_xz_target_recent_change = 20;
            printf('new xz_target: lat=%s lon=%s', pos.lat(), pos.lon());
            auto_hover_xz_target_prime_window.close();
        }
    }
    
    settimer( func { auto_hover_xz_target()}, 0.2);
}

auto_hover_xz_target();
