import QtQuick
import Quickshell
import Quickshell.Wayland

// One transparent layer-shell surface per monitor, holding the pets that walk
// on it.
//
// The surface covers the whole output but is click-through everywhere except
// the few sprite-sized rectangles in `mask`, so the desktop underneath behaves
// exactly as it did before the pet arrived. It sits on the Top layer: above
// ordinary windows, which is where a pet standing on a title bar has to be,
// and below the overlay surfaces (menu, OSD, lock) so it never covers them.
PanelWindow {
  // Not `surface`: PetView declares its own `surface` property, and QML resolves
  // the right-hand side of `surface: surface` against the delegate's own
  // properties before this id -- so the delegate bound itself to undefined and
  // every pet silently stopped being drawn.
  id: petSurface

  required property var host
  property string screenName: ""

  readonly property bool busy: host ? host.fullscreenOn(screenName) : false

  visible: host !== null && host.pets.length > 0 && !busy

  anchors {
    top: true
    bottom: true
    left: true
    right: true
  }

  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "omarchy-esheep"
  WlrLayershell.layer: WlrLayer.Top
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

  // Input lands on the pets and nowhere else. An empty list makes the whole
  // surface transparent to the pointer.
  property var petRegions: []
  mask: Region { regions: petSurface.petRegions }

  function addRegion(region) {
    if (!region) return
    var next = petRegions.slice()
    if (next.indexOf(region) !== -1) return
    next.push(region)
    petRegions = next
  }

  function removeRegion(region) {
    var next = []
    for (var i = 0; i < petRegions.length; i++) if (petRegions[i] !== region) next.push(petRegions[i])
    if (next.length === petRegions.length) return
    petRegions = next
  }

  // Every surface draws every pet, and culls the ones its own screen cannot
  // see. That is what makes a pet halfway through a screen edge appear on both
  // monitors at once, whether it is walking across or being dragged across, so
  // this model stays unfiltered.
  Repeater {
    model: petSurface.host ? petSurface.host.pets : []

    delegate: PetView {
      required property var modelData
      agent: modelData
      surface: petSurface
    }
  }
}
