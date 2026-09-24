// mixctl: peak/rms meters on SC buses, relayed to the mixctl sidecar.
//
// sclang compiles every .sc under dust/code, even for disabled mods, so this
// file must not reference optional classes (e.g. FxSetup) by name. fx mod
// send buses are found through ~sendA / ~sendB, and FxSetup through a
// runtime class lookup.

MixCtl {
	classvar <group, <synths, <sidecar, <matron, <ids;

	*initClass {
		ids = [\sc_main, \sc_sendA, \sc_sendB];
		synths = [];
		StartUp.add {
			sidecar = NetAddr("127.0.0.1", 8740);
			matron = NetAddr("127.0.0.1", 10111);

			SynthDef(\mixctlMeter, { |in = 0, id = 0, rate = 20|
				SendPeakRMS.kr(In.ar(in, 2), rate, 3, '/mixctl/meter', id);
			}).add;

			OSCFunc.new({ MixCtl.build }, "/mixctl/init");
			OSCFunc.new({ MixCtl.free }, "/mixctl/cleanup");
			OSCFunc.new({ MixCtl.queryInserts }, "/mixctl/inserts");

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
		var buses = [
			s.outputBus.index,
			this.busIndex(topEnvironment[\sendA]),
			this.busIndex(topEnvironment[\sendB])
		];
		this.free;
		// root tail runs after the default group (and FxSetup.fxGroup at its
		// tail), so bus 0 is read post-insert and the sends see every writer
		group = Group.new(RootNode(s), \addToTail);
		buses.do { |index, i|
			if (index.notNil, {
				synths = synths.add(Synth.new(\mixctlMeter, [\in, index, \id, i], group));
			});
		};
		"mixctl: % meters".postf(synths.size);
		"".postln;
	}

	// fx in the insert slot run in series in node order: each new one is added
	// to the tail of FxSetup.insertGroup, followed by its replacer. read that
	// order from the server and send it to matron as fx subpath names
	// (e.g. "fx_dverb"), first to last.
	*queryInserts {
		var s = Server.default;
		var fx = \FxSetup.asClass;
		var grp, names;
		if (fx.isNil, { ^this });
		grp = fx.insertGroup;
		if (grp.isNil, { matron.sendMsg("/mixctl/inserts"); ^this });
		// synthdef name -> subpath without the leading slash
		names = IdentityDictionary.new;
		fx.plugins.do { |p|
			names[p.symbol.asSymbol] = p.subPath.asString.replace("/", "");
		};
		OSCFunc.new({ |msg|
			// [cmd, flag, nodeID, numChildren, then per child: nodeID, numChildren,
			// and a defName when numChildren is -1 (a synth)]
			var order = List.new;
			var i = 4;
			var walk;
			walk = { |count|
				count.do {
					var n = msg[i + 1];
					if (n == -1, {
						var name = names[msg[i + 2].asSymbol];
						if (name.notNil, { order.add(name) });
						i = i + 3;
					}, {
						i = i + 2;
						walk.value(n);
					});
				};
			};
			walk.value(msg[3]);
			matron.sendMsg("/mixctl/inserts", *order.asArray);
		}, '/g_queryTree.reply', s.addr, argTemplate: [0, grp.nodeID]).oneShot;
		s.sendMsg("/g_queryTree", grp.nodeID, 0);
	}

	*free {
		if (group.notNil, { group.free });
		group = nil;
		synths = [];
	}
}
