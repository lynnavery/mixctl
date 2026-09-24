// mixctl: peak/rms meters on SC buses, relayed to the mixctl sidecar.
//
// sclang compiles every .sc under dust/code, even for disabled mods, so this
// file must not reference optional classes (e.g. FxSetup) by name. fx mod
// buses are found through ~sendA / ~sendB and a runtime class lookup.

MixCtl {
	classvar <group, <synths, <sidecar, <ids;

	*initClass {
		ids = [\sc_main, \sc_sendA, \sc_sendB, \sc_wet];
		synths = [];
		StartUp.add {
			sidecar = NetAddr("127.0.0.1", 8740);

			SynthDef(\mixctlMeter, { |in = 0, id = 0, rate = 20|
				SendPeakRMS.kr(In.ar(in, 2), rate, 3, '/mixctl/meter', id);
			}).add;

			OSCFunc.new({ MixCtl.build }, "/mixctl/init");
			OSCFunc.new({ MixCtl.free }, "/mixctl/cleanup");

			// from scsynth: [cmd, nodeID, replyID, peakL, rmsL, peakR, rmsR]
			OSCFunc.new({ |msg|
				var name = ids[msg[2].asInteger];
				if (name.notNil, {
					sidecar.sendMsg("/mixctl/meter", name, msg[3], msg[4], msg[5], msg[6]);
				});
			}, "/mixctl/meter");
		};
	}

	*busIndex { |bus|
		^if (bus.isNil, { nil }, { bus.index });
	}

	*build {
		var s = Server.default;
		var fxClass = \FxSetup.asClass;
		var buses = [
			s.outputBus.index,
			this.busIndex(topEnvironment[\sendA]),
			this.busIndex(topEnvironment[\sendB]),
			if (fxClass.notNil, { this.busIndex(fxClass.wet) }, { nil })
		];
		this.free;
		// root tail runs after the default group, so it sees every writer,
		// including fx inserts
		group = Group.new(RootNode(s), \addToTail);
		buses.do { |index, i|
			if (index.notNil, {
				synths = synths.add(Synth.new(\mixctlMeter, [\in, index, \id, i], group));
			});
		};
		"mixctl: % meters".postf(synths.size);
		"".postln;
	}

	*free {
		if (group.notNil, { group.free });
		group = nil;
		synths = [];
	}
}
