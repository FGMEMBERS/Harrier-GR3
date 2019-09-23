# Increment a property, constraining to min/max values, and using interpolate()
# with specified time period.
#
var incrementProp = func(name, delta, min, max, t) {
    value = getprop(name);
    
    # Ensure that we end up at a multiple of <delta> if we get called while
    # property is still moving from an earlier interpolation.
    #
    if (delta > 0)      value = delta * math.ceil(value / delta);
    else if (delta < 0) value = (-delta) * math.floor(value / (-delta));
    
    value += delta;
    if (value < min)    value = min;
    if (value > max)    value = max;
    interpolate(name, value, t);
}
# HARRIER controls
#  extra check to see if the harrier is carrying its AAR boom


var UPDATE_PERIOD = 0.3;


var update_loop = func {

    var hasAARBoom = getprop("sim/weight[7]/selected") != "none";
	var s = props.globals.getNode("systems/refuel/serviceable");
	s.setBoolValue(0);
    if ( hasAARBoom ){
        s.setBoolValue(1);
    }
	
    settimer(update_loop, UPDATE_PERIOD);
}


setlistener("/sim/signals/fdm-initialized", func {
	update_loop();
});
