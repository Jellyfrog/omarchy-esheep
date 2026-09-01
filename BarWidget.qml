import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Settings.js" as Settings

// The bar button and its panel: how many pets, which pet, how big, how fast,
// and what they are allowed to climb on.
//
// Everything here writes to the same shell.json entry the overlay reads, so
// the pets react as the panel is used -- there is no separate state to keep in
// step.
Panel {
  id: root

  moduleName: "jellyfrog.esheep"

  // Panel chrome, declared once and passed down, the way the first-party
  // panels do it. `dim` is the muted variant used for secondary text.
  readonly property color foreground: Color.popups.text
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property string fontFamily: Style.font.family

  // What the panel edits, defaults filled in. The bar host hands us the raw
  // entry from shell.json; `settings` on the base class is that entry.
  readonly property var values: Settings.normalize(Settings.migrate(settings))

  // Roaming is only a question when there is somewhere to roam to -- and when
  // the workspace lock is not already answering it. Settings.roamingPermitted
  // is where that rule lives, so the toggle dims on exactly the terms the
  // overlay uses to decide where a pet may walk.
  readonly property bool multiMonitor: Quickshell.screens.length > 1
  readonly property bool canRoam: multiMonitor && Settings.roamingPermitted(values)
  // What the toggle shows: the same answer the overlay walks by, so a config
  // where both shipped on cannot display a promise it will break.
  readonly property bool roamingOn: Settings.roamingOn(values)

  // There is no separate on/off: asking for no pets is what "off" means.
  readonly property bool petsEnabled: petCount > 0
  readonly property string petId: values.pet
  readonly property int petCount: values.count

  readonly property url iconUrl: Qt.resolvedUrl("assets/" + petId + "/icon.png")

  property var catalogue: []

  readonly property var currentPet: {
    for (var i = 0; i < catalogue.length; i++) {
      if (catalogue[i] && catalogue[i].id === petId) return catalogue[i]
    }
    return null
  }

  readonly property string petTitle: currentPet
    ? String(currentPet.title || currentPet.name || petId)
    : petId

  readonly property var petOptions: {
    var options = []
    for (var i = 0; i < catalogue.length; i++) {
      var pet = catalogue[i]
      if (!pet) continue
      options.push({ value: String(pet.id), label: String(pet.title || pet.name || pet.id) })
    }
    return options
  }

  // Every change is one write of the whole entry, which is how the bar host
  // persists widget settings.
  function update(changes) {
    var entry = Settings.merge(settings, moduleName, changes)
    // Applied locally first so the panel responds on the click itself; the
    // shell.json write comes back through the bar as the same values.
    settings = entry
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(moduleName, entry)
  }

  // Settings.merge does the clamping, so this can just ask for one more.
  function setCount(next) {
    update({ count: Math.round(next) })
  }

  function togglePets() { setCount(Settings.countFor(!petsEnabled, petCount)) }

  // Turning the lock on sends roaming off with it: a pet that walks onto the
  // next monitor joins whatever workspace that monitor is showing, so the two
  // cannot both be had. Written rather than merely dimmed, so `omarchy bar set`
  // and a hand-edited shell.json tell the same story the panel does. Turning
  // the lock back off does not bring roaming back -- no shadow copy of it is
  // kept, for the same reason the pet count keeps none.
  function setLockToWorkspace(on) {
    update(on ? { lockToWorkspace: true, roamMonitors: false }
              : { lockToWorkspace: false })
  }

  FileView {
    path: Qt.resolvedUrl("assets/pets.json")
    printErrors: false
    onLoaded: {
      try {
        var parsed = JSON.parse(text())
        root.catalogue = Array.isArray(parsed.pets) ? parsed.pets : []
      } catch (e) {
        root.catalogue = []
      }
    }
    onLoadFailed: root.catalogue = []
  }

  // ---------------------------------------------------------- keyboard cursor

  // A flat list of the things Enter can act on, in the order they are drawn.
  // The rest of the settings live in the manifest schema, so Setup > Bar can
  // reach them without this panel growing past the bottom of a small screen.
  readonly property var actions: ["fewer", "more", "pet", "walkOnWindows", "lockToWorkspace"]
    .concat(canRoam ? ["roamMonitors"] : [])
  property int cursor: -1

  function moveCursor(delta) {
    if (cursor < 0) { cursor = 0; return }
    cursor = Math.max(0, Math.min(actions.length - 1, cursor + delta))
  }

  function activateCursor() {
    switch (actions[cursor]) {
      case "fewer": setCount(petCount - 1); break
      case "more": setCount(petCount + 1); break
      case "pet": petDropdown.toggle(); break
      case "walkOnWindows": update({ walkOnWindows: !values.walkOnWindows }); break
      case "roamMonitors": update({ roamMonitors: !values.roamMonitors }); break
      case "lockToWorkspace": setLockToWorkspace(!values.lockToWorkspace); break
    }
  }

  function cursorOn(name) { return cursor >= 0 && actions[cursor] === name }
  function takeCursor(name, hovered) { if (hovered) cursor = actions.indexOf(name) }

  onOpenedChanged: if (!opened) cursor = -1

  // A section title, and a slider wired straight to one setting. Both exist
  // so adding a control is one line rather than nine.
  component SectionHeader: PanelSectionHeader {
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  component SettingSlider: PanelSlider {
    required property string key
    property real quantum: 0.25
    height: Style.spacing.controlHeight
    bar: root.bar
    onMoved: function(value) {
      var change = {}
      change[key] = Math.round(value / quantum) * quantum
      root.update(change)
    }
  }

  // ------------------------------------------------------------------ button

  // The bar gives this item the width it asks for, and the button is anchored
  // to us rather than the other way round, so the size has to travel back up.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // The pet's own icon, so the bar shows what is walking around down there.
    iconComponent: petIcon
    dimmed: !root.petsEnabled
    tooltipText: ""

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) root.togglePets()
      else if (mouseButton === Qt.MiddleButton) root.setCount(root.petCount + 1)
      else root.toggle()
    }
  }

  Component {
    id: petIcon
    Image {
      anchors.fill: parent
      source: root.iconUrl
      sourceSize.width: Style.bar.iconCanvas * 4
      sourceSize.height: Style.bar.iconCanvas * 4
      smooth: true
      fillMode: Image.PreserveAspectFit
    }
  }

  // ------------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { root.moveCursor(dy !== 0 ? dy : dx) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Component {
        id: heroIcon
        Image {
          anchors.fill: parent
          source: root.iconUrl
          sourceSize.width: 96
          sourceSize.height: 96
          fillMode: Image.PreserveAspectFit
        }
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // ---------- Hero: who is on your desktop right now ----------
        PanelHero {
          width: parent.width
          iconComponent: heroIcon
          iconOpacity: root.petsEnabled ? 1 : 0.4
          foreground: root.foreground
          fontFamily: root.fontFamily
          title: root.petTitle
          meta: {
            if (root.petCount === 0) return "Nobody home"
            var who = root.petCount === 1 ? "1 on your desktop" : root.petCount + " on your desktop"
            return who + (root.currentPet && root.currentPet.author ? " · by " + root.currentPet.author : "")
          }
        }

        // ---------- How many ----------
        Item {
          width: parent.width
          implicitHeight: Style.spacing.controlHeight

          PanelActionButton {
            id: fewer
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            iconText: "−"
            tooltipText: "One fewer"
            bordered: true
            foreground: root.foreground
            enabled: root.petCount > 0
            opacity: enabled ? 1 : 0.4
            hasCursor: root.cursorOn("fewer")
            onHovered: function(isHovered) { root.takeCursor("fewer", isHovered) }
            onClicked: root.setCount(root.petCount - 1)
          }

          Text {
            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: root.petCount === 1 ? "1 pet" : root.petCount + " pets"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
          }

          PanelActionButton {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "+"
            tooltipText: "One more"
            bordered: true
            foreground: root.foreground
            enabled: root.petCount < Settings.MAX_PETS
            opacity: enabled ? 1 : 0.4
            hasCursor: root.cursorOn("more")
            onHovered: function(isHovered) { root.takeCursor("more", isHovered) }
            onClicked: root.setCount(root.petCount + 1)
          }
        }

        PanelSeparator { width: parent.width; foreground: root.foreground }

        SectionHeader { text: "Which pet" }

        Dropdown {
          id: petDropdown
          width: parent.width
          showLabel: false
          options: root.petOptions
          value: root.petId
          hasCursor: root.cursorOn("pet")
          onHovered: function(isHovered) { root.takeCursor("pet", isHovered) }
          onChanged: function(value) {
            root.update({ pet: String(value), count: Settings.countFor(true, root.petCount) })
          }
        }

        SectionHeader { text: "Size" }

        SettingSlider {
          width: parent.width
          key: "scale"
          quantum: 0.5
          minimum: 1
          maximum: 4
          step: 0.5
          value: root.values.scale
        }

        SectionHeader { text: "Speed" }

        SettingSlider {
          width: parent.width
          key: "speed"
          quantum: 0.25
          minimum: 0.5
          maximum: 2
          step: 0.25
          value: root.values.speed
        }

        PanelSeparator { width: parent.width; foreground: root.foreground }

        SectionHeader { text: "Behaviour" }

        Toggle {
          width: parent.width
          label: "Climb on windows"
          description: "Land on the top edge of a window and walk along it."
          foreground: root.foreground
          checked: root.values.walkOnWindows
          hasCursor: root.cursorOn("walkOnWindows")
          onHovered: function(isHovered) { root.takeCursor("walkOnWindows", isHovered) }
          onClicked: root.update({ walkOnWindows: !root.values.walkOnWindows })
        }

        Toggle {
          width: parent.width
          label: "Keep to one workspace"
          description: "A pet stays on the workspace it appeared on."
          foreground: root.foreground
          checked: root.values.lockToWorkspace
          hasCursor: root.cursorOn("lockToWorkspace")
          onHovered: function(isHovered) { root.takeCursor("lockToWorkspace", isHovered) }
          onClicked: root.setLockToWorkspace(!root.values.lockToWorkspace)
        }

        Toggle {
          width: parent.width
          visible: root.multiMonitor
          height: visible ? implicitHeight : 0
          label: "Roam between monitors"
          description: "Walk onto the next screen where two of them touch."
          foreground: root.foreground
          // Dimmed and out of the keyboard cursor's way while the lock is on,
          // the way the count buttons dim when there is nothing left to count.
          enabled: root.canRoam
          opacity: enabled ? 1 : 0.4
          checked: root.roamingOn
          hasCursor: root.cursorOn("roamMonitors")
          onHovered: function(isHovered) { root.takeCursor("roamMonitors", isHovered) }
          onClicked: root.update({ roamMonitors: !root.values.roamMonitors })
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          wrapMode: Text.WordWrap
          text: "Drag a pet with the left button. Send one away with the right."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
