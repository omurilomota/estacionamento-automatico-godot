class_name DatasetRecorder
extends RefCounted
## Behavior-cloning CSV writer (extracted from Carro._ml_gravar_linha).
## Row contract v2 (24 cols, F1): 22 normalized features + steering_norm
## (-1..1 = estercamento_alvo / max_estercamento) + speed_norm
## (0..1 = velocidade_desejada / velocidade_maxima), all "%.4f".
## Feature order: [0..10] 11 ray distances (0 = touching, 1 = free);
## [11] speed/vmax; [12] dist_to_spot/2500; [13,14] sin/cos angle-to-spot;
## [15..17] DEAD arrow slots (always 0.0, setas ignored — locked B5,
## kept so old 18-col readers stay aligned); [18] yaw_error/pi;
## [19] corridor_width/2000 clamped; [20] crosser_dist/2500 (1.0 = none);
## [21] stuck_time/10 clamped.
## NOTE: v1 files (ml/dados/*.csv, 20 cols) train the v1 18-32-16-2 net;
## v2 recorders write 24 cols for the future 22-input net (locked C8).

const FEATURE_COUNT := 22
const COLUMN_COUNT := 24
const V1_FEATURE_COUNT := 18


## Opens (or reopens) the CSV path for writing.
static func open(path: String) -> FileAccess:
	return FileAccess.open(path, FileAccess.WRITE)


## Formats one training row from ALREADY-NORMALIZED labels.
static func format_row(features: PackedFloat64Array, steering_norm: float, speed_norm: float) -> String:
	var cols: PackedStringArray = PackedStringArray()
	for v in features:
		cols.append("%.4f" % v)
	cols.append("%.4f" % clampf(steering_norm, -1.0, 1.0))
	cols.append("%.4f" % clampf(speed_norm, 0.0, 1.0))
	return ",".join(cols)


static func valid_row(features: PackedFloat64Array) -> bool:
	return features.size() == COLUMN_COUNT - 2


## True when this row came from a v1 (18-feature, 20-col) file.
static func is_v1_row(features: PackedFloat64Array) -> bool:
	return features.size() == V1_FEATURE_COUNT
