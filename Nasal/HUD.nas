# turn off hud in external views

var update_visibility = func(n) {
    var visible = 0;
    if ( getprop("sim/current-view/view-number") == 0
            and getprop("sim/current-view/multiplayer")==0
            ) {
        visible = 1;
    }
    setprop("sim/hud/visibility[1]", visible);
}

setlistener("sim/current-view/view-number", update_visibility);
setlistener("sim/current-view/multiplayer", update_visibility);
