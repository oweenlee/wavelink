export interface Track {
	id: number;
	path: string;
	title: string | null;
	artist: string | null;
	album: string | null;
	album_artist: string | null;
	track_number: number | null;
	disc_number: number | null;
	year: number | null;
	genre: string | null;
	duration: number | null;
	sample_rate: number | null;
	channels: number | null;
	format: string | null;
	file_size: number | null;
	file_modified: number | null;
	date_added: number;
	play_count: number;
	last_played: number | null;
	rating: number;
	missing: boolean;
}

export interface PeqBand {
	freq: number;
	gain_db: number;
	q: number;
}

export interface AlbumBrief {
	artist: string;
	album: string;
	first_track_id: number;
	first_track_path: string;
	year: number | null;
}
