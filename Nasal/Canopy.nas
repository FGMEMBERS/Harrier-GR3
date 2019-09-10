# used to the animation of the canopy switch and the canopy move
# toggle keystroke or 2 position switch

var cnpy = aircraft.door.new("canopy", 10);
var switch = props.globals.getNode("sim/model/Harrier-GR3/controls/canopy/canopy-switch", 1);

switch.setValue(1);

var canopy_switch = func(v) {
    if (v == 2) {
        # Toggle
        if (switch.getValue() == 1) {
            v = 3;
        }
        else if (switch.getValue() == 3) {
            v = 1;
        }
    }
    if (v == 1) {
        cnpy.close();
    }
    else if (v == 3) {
        cnpy.open();
    }
    switch.setValue(v);
}

# fixes cockpit when use of ac_state.nas #####
var cockpit_state = func {
    var switch = getprop("sim/model/Harrier-GR3/controls/canopy/canopy-switch");
    if ( switch == 1 ) {
        setprop("canopy/position-norm", 0);
    }
}

