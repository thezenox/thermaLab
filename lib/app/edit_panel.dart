import 'package:flutter/material.dart';

import '../probe/probe_controller.dart';
import '../render/palette.dart';
import '../render/scene_layout.dart';

const Color _gold = Color(0xFFD4A84B);
const BorderRadius _radius = BorderRadius.all(Radius.circular(6));

/// Edit mode controls: every display setting with a live preview in the
/// image below. Clock and colour bar are moved by dragging them there.
class EditPanel extends StatelessWidget {
  const EditPanel({super.key, required this.controller, required this.onDone});

  final ProbeController controller;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final ProbeController c = controller;
    final SceneLayout l = c.layout;
    void layout(SceneLayout v) => c.setLayout(v, persist: false);

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 6),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1B1B1E),
        borderRadius: const BorderRadius.all(Radius.circular(10)),
        border: Border.all(color: const Color(0xFF333338)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Expanded(
                child: Text(
                  'Arrange display',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
              TextButton(
                onPressed: () => layout(const SceneLayout()),
                child: const Text('Reset layout'),
              ),
              const SizedBox(width: 4),
              FilledButton(
                style: FilledButton.styleFrom(
                  shape: const RoundedRectangleBorder(borderRadius: _radius),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: onDone,
                child: const Text('Done'),
              ),
            ],
          ),
          const Text(
            'Drag clock and colour bar in the image to move them.',
            style: TextStyle(fontSize: 12, color: Colors.white54),
          ),
          _Section(
            title: 'Show',
            children: <Widget>[
              _Toggle(
                icon: Icons.schedule,
                label: 'Clock',
                on: l.showClock,
                onTap: () => layout(l.copyWith(showClock: !l.showClock)),
              ),
              _Toggle(
                icon: Icons.linear_scale,
                label: 'Colour bar',
                on: l.showScale,
                onTap: () => layout(l.copyWith(showScale: !l.showScale)),
              ),
              _Toggle(
                icon: Icons.add,
                label: 'Centre',
                on: l.showCentre,
                onTap: () => layout(l.copyWith(showCentre: !l.showCentre)),
              ),
              _Toggle(
                icon: Icons.change_history,
                label: 'Max',
                on: l.showHottest,
                onTap: () => layout(l.copyWith(showHottest: !l.showHottest)),
              ),
              _Toggle(
                icon: Icons.details,
                label: 'Min',
                on: l.showColdest,
                onTap: () => layout(l.copyWith(showColdest: !l.showColdest)),
              ),
            ],
          ),
          _Section(
            title: 'Image',
            children: <Widget>[
              _Toggle(
                icon: Icons.rotate_90_degrees_cw,
                label: '${c.quarterTurns * 90}°',
                on: false,
                onTap: () => c.applySetting('quarterTurns', c.quarterTurns + 1),
              ),
              _Toggle(
                icon: Icons.flip,
                label: 'Mirror',
                on: c.mirror,
                onTap: () => c.applySetting('mirror', !c.mirror),
              ),
              for (final Palette p in Palette.all)
                _Toggle(
                  swatch: p,
                  label: p.name,
                  on: c.palette == p,
                  onTap: () => c.setPalette(p),
                ),
            ],
          ),
          _Section(
            title: 'View',
            children: <Widget>[
              _Toggle(
                icon: Icons.screen_rotation_alt,
                label: 'Turn display ${c.viewTurns * 90}°',
                on: false,
                onTap: () => c.applySetting('viewTurns', c.viewTurns + 1),
              ),
            ],
          ),
          _Section(
            title: 'Label outline',
            children: <Widget>[
              for (final (int v, String name) in const <(int, String)>[
                (0, 'Shadow'),
                (1, 'Normal'),
                (2, 'Thick'),
              ])
                _Toggle(
                  label: name,
                  on: c.labelOutline == v,
                  onTap: () => c.applySetting('labelOutline', v),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title.toUpperCase(),
            style: const TextStyle(
              fontSize: 11,
              letterSpacing: 0.9,
              fontWeight: FontWeight.w600,
              color: Colors.white54,
            ),
          ),
          const SizedBox(height: 5),
          Wrap(spacing: 6, runSpacing: 6, children: children),
        ],
      ),
    );
  }
}

/// Compact button with a small corner radius; gold when switched on.
class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.label,
    required this.on,
    required this.onTap,
    this.icon,
    this.swatch,
  });

  final String label;
  final bool on;
  final VoidCallback onTap;
  final IconData? icon;
  final Palette? swatch;

  @override
  Widget build(BuildContext context) {
    final Color fg = on ? Colors.black : Colors.white;
    return Material(
      color: on ? _gold : const Color(0xFF2A2A2E),
      shape: RoundedRectangleBorder(
        borderRadius: _radius,
        side: BorderSide(color: on ? _gold : const Color(0xFF3A3A40)),
      ),
      child: InkWell(
        borderRadius: _radius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: 16, color: fg),
                const SizedBox(width: 6),
              ],
              if (swatch != null) ...<Widget>[
                _Swatch(swatch!),
                const SizedBox(width: 6),
              ],
              Text(label, style: TextStyle(fontSize: 13, color: fg)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch(this.palette);

  final Palette palette;

  @override
  Widget build(BuildContext context) {
    Color at(int i) {
      final int v = palette.rgba[i];
      return Color(
        (v & 0xFF00FF00) | ((v & 0xFF) << 16) | ((v >> 16) & 0xFF),
      );
    }

    return Container(
      width: 22,
      height: 10,
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.all(Radius.circular(2)),
        gradient: LinearGradient(
          colors: <Color>[for (int i = 0; i < 256; i += 51) at(i), at(255)],
        ),
      ),
    );
  }
}
