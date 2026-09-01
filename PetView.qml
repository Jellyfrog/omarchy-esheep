import QtQuick
import Quickshell

// One pet, drawn on one monitor.
//
// A pet belongs to a monitor but is drawn by every surface it overlaps, which
// is what lets you drag one across a monitor edge and watch it arrive. Only
// the surface that owns it carries its input region, so a pet is grabbed once
// however many screens can see it.
Item {
  id: view

  required property var agent
  required property var surface

  readonly property var host: surface ? surface.host : null
  readonly property int tilesX: host && host.tilesX > 0 ? host.tilesX : 1

  // The pet's own monitor decides what its coordinates mean; this surface
  // then places it relative to the screen it draws.
  readonly property var area: host && agent ? host.areaFor(agent.screenName) : null
  readonly property real screenX: surface && surface.screen ? surface.screen.x : 0
  readonly property real screenY: surface && surface.screen ? surface.screen.y : 0
  readonly property real globalX: area && agent ? area.x + agent.petX : 0
  readonly property real globalY: area && agent ? area.y + agent.petY + agent.verticalOffset : 0

  readonly property bool owned: agent && surface ? agent.screenName === surface.screenName : false
  // Children are along for the ride; only the pets the user asked for can be
  // picked up -- and only while someone is looking at them. A pet pinned to a
  // workspace nobody is on must give its input region back, or it goes on
  // eating the clicks meant for the window it is standing invisibly in front of.
  readonly property bool interactive: owned && agent && !agent.isChild && !agent.leaving
    && agent.onCurrentWorkspace

  // The same rectangle the engine collides with, so what you see is what the
  // pet stands on.
  width: host ? host.spriteWidth : 0
  height: host ? host.spriteHeight : 0
  x: Math.round(globalX - screenX)
  y: Math.round(globalY - screenY)
  opacity: agent ? Math.max(0, Math.min(1, agent.alpha)) : 1
  clip: true

  // Whether this surface can see the pet at all: the copies that fall outside
  // this monitor entirely are not worth painting.
  //
  // This culls the sprite rather than the view, and that distinction is the
  // whole point. The view carries the MouseArea that holds a drag, and a Qt
  // item that goes invisible loses its mouse grab -- so hiding the view here
  // cancelled the drag the instant the pet cleared its own monitor, dropped it,
  // and let the engine walk it back to the edge it came from. Painting is this
  // property's business; who may grab the pet is `interactive`'s.
  readonly property bool paintable: agent !== null && area !== null
    && agent.onCurrentWorkspace
    && x + width > 0 && x < (surface && surface.screen ? surface.screen.width : 0)
    && y + height > 0 && y < (surface && surface.screen ? surface.screen.height : 0)

  transform: Scale {
    origin.x: view.width / 2
    xScale: view.agent && view.agent.mirrored ? -1 : 1
  }

  Image {
    id: sheet
    visible: view.paintable
    source: view.host ? view.host.sheetUrl : ""
    sourceSize.width: view.host ? view.host.sheetWidth : 0
    sourceSize.height: view.host ? view.host.sheetHeight : 0
    // Sized in whole sprites so every tile lands exactly on the view, however
    // the magnification rounds.
    width: view.width * view.tilesX
    height: view.height * (view.host ? view.host.tilesY : 1)
    // Pixel art: nearest-neighbour magnification keeps the sprite crisp
    // instead of turning a 40px sheep into a smudge.
    smooth: false
    mipmap: false
    cache: true
    x: -(view.agent ? view.agent.frame % view.tilesX : 0) * view.width
    y: -Math.floor((view.agent ? view.agent.frame : 0) / view.tilesX) * view.height
  }

  // The pointer's implicit grab keeps motion coming to this surface once the
  // button is down, so a drag can leave the pet's own monitor.
  property real grabOffsetX: 0
  property real grabOffsetY: 0

  function pointerGlobal(mouseX, mouseY) {
    var point = view.mapToItem(null, mouseX, mouseY)
    return { x: point.x + view.screenX, y: point.y + view.screenY }
  }

  MouseArea {
    anchors.fill: parent
    enabled: view.interactive
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor

    onPressed: function(mouse) {
      if (mouse.button === Qt.RightButton) {
        // The old eSheep sent a pet away with the right button; so does this
        // one, farewell animation and all.
        view.host.dismissPet(view.agent)
        mouse.accepted = true
        return
      }
      var pointer = view.pointerGlobal(mouse.x, mouse.y)
      view.grabOffsetX = pointer.x - view.globalX
      view.grabOffsetY = pointer.y - view.globalY
      view.agent.grab()
    }

    onPositionChanged: function(mouse) {
      if (!pressed || !view.agent || !view.agent.dragging) return
      var pointer = view.pointerGlobal(mouse.x, mouse.y)
      if (!view.area) return
      view.agent.dragTo(pointer.x - view.grabOffsetX - view.area.x,
                        pointer.y - view.grabOffsetY - view.area.y)
    }

    onReleased: function(mouse) {
      if (!view.agent || !view.agent.dragging) return
      var pointer = view.pointerGlobal(mouse.x, mouse.y)
      var dropX = pointer.x - view.grabOffsetX
      var dropY = pointer.y - view.grabOffsetY
      // Dropped over another monitor: hand the pet over before it falls, so
      // it lands on the floor it was dropped onto.
      var target = view.host.screenNameAt(dropX + view.width / 2, dropY + view.height / 2)
      if (target && target !== view.agent.screenName) view.host.moveToScreen(view.agent, target, dropX, dropY)
      view.agent.release()
    }

    onCanceled: if (view.agent && view.agent.dragging) view.agent.release()
  }

  // The pointer only reaches the sprite: everything else on this surface is
  // click-through, and the region follows the pet as it walks.
  //
  // The geometry is spelled out rather than handed to Region's `item`, which
  // measures with mapToScene: under the mirror transform that maps the
  // top-left corner to the top-right, and the region comes out
  // negative-width -- an empty input region, so a pet facing right could not
  // be picked up.
  property Region maskRegion: Region {
    x: Math.round(view.x)
    y: Math.round(view.y)
    width: Math.round(view.width)
    height: Math.round(view.height)
  }

  onInteractiveChanged: {
    if (!surface) return
    if (interactive) surface.addRegion(maskRegion)
    else surface.removeRegion(maskRegion)
  }

  Component.onCompleted: if (interactive && surface) surface.addRegion(maskRegion)
  Component.onDestruction: if (surface) surface.removeRegion(maskRegion)
}
