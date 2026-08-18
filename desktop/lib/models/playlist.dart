/// A user-created playlist. Track membership is stored by [Track.id] so the
/// list survives restarts and re-scans of the music folder.
class Playlist {
  final String id;
  final String name;
  final List<String> trackIds;

  const Playlist({
    required this.id,
    required this.name,
    this.trackIds = const [],
  });

  Playlist copyWith({String? name, List<String>? trackIds}) {
    return Playlist(
      id: id,
      name: name ?? this.name,
      trackIds: trackIds ?? this.trackIds,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'trackIds': trackIds,
      };

  factory Playlist.fromJson(Map<String, dynamic> j) => Playlist(
        id: j['id'] as String,
        name: j['name'] as String,
        trackIds: (j['trackIds'] as List<dynamic>? ?? [])
            .map((e) => e as String)
            .toList(),
      );

  @override
  String toString() => name;
}
