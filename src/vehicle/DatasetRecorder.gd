class_name DatasetRecorder
extends RefCounted
## Behavior-cloning CSV writer (extracted from Carro._ml_gravar_linha).
## Row contract (20 cols): 18 normalized features + steering_norm
## (-1..1 = estercamento_alvo / max_estercamento) + speed_norm
## (0..1 = velocidade_desejada / velocidade_maxima), all "%.4f".
## Matches ml/treinar.py (N_ENTRADAS=18, N_SAIDAS=2, col 19 = speed/160).

const COLUMN_COUNT := 20


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
