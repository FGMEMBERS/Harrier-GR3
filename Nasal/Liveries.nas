aircraft.livery.init("Aircraft/Harrier-GR3/Models/Liveries");

# Encode our stores and weapons into /sim/model/variant as a bit field
var stores = [];
var variant = nil;

var variant_encoder = maketimer (1.0, func () {
   var v = 0;
   foreach (var s; stores) {
      v *= 2;
      if (s.getValue() != "none") {
         v += 1;
      }
   }
   variant.setValue (v);
});


var init_stores = setlistener ("/sim/signals/fdm-initialized", func () {
   print ("Variant encoder init...");
   removelistener (init_stores); # only call once
   variant = props.globals.initNode ("/sim/model/variant", 0, "INT");
   foreach (var w; props.globals.getNode ("/sim").getChildren ("weight")) {
      stores ~= [ w.getNode ("selected") ] ;
   }
   variant_encoder.start();
   print ("Done.");
});
