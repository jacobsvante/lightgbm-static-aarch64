use lgbm::{
    Booster, Dataset, Field, MatBuf, Parameters,
};
use std::sync::Arc;

fn main() {
    let p = Parameters::new();
    let mut train = Dataset::from_mat(&MatBuf::from_rows(train_features()), None, &p).unwrap();
    train.set_field(Field::LABEL, &train_labels()).unwrap();
    let _b = Booster::new(Arc::new(train), &p).unwrap();
}

fn train_features() -> Vec<[f64; 1]> {
    (0..128).map(|x| [(x % 3) as f64]).collect()
}

fn train_labels() -> Vec<f32> {
    (0..128).map(|x| (x % 3) as f32).collect()
}
