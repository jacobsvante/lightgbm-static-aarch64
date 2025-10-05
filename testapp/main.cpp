#include <iostream>
#include <vector>
#include <memory>
#include <cstring>
#include <thread>
#ifdef _OPENMP
#include <omp.h>
#endif
#include <LightGBM/c_api.h>

void printBuildInfo() {
    std::cout << "LightGBM Build Information" << std::endl;
    std::cout << "==========================" << std::endl;

    // Check OpenMP support via thread count
    std::cout << "Hardware threads available: " << std::thread::hardware_concurrency() << std::endl;

    // Check if OpenMP is functional by trying parallel execution
    #ifdef _OPENMP
        std::cout << "OpenMP: ENABLED (compiled with OpenMP support)" << std::endl;
        #pragma omp parallel
        {
            #pragma omp single
            {
                std::cout << "OpenMP threads: " << omp_get_num_threads() << std::endl;
            }
        }
    #else
        std::cout << "OpenMP: DISABLED (not compiled with OpenMP support)" << std::endl;
    #endif

    // Architecture detection
    std::cout << "Architecture: " <<
        #ifdef __aarch64__
            "aarch64 (ARM 64-bit)"
        #elif defined(__x86_64__)
            "x86_64 (Intel/AMD 64-bit)"
        #elif defined(__arm__)
            "ARM 32-bit"
        #else
            "unknown"
        #endif
        << std::endl;

    // Check for SIMD support
    #ifdef __ARM_NEON
        std::cout << "NEON SIMD: ENABLED" << std::endl;
    #else
        std::cout << "NEON SIMD: Not detected" << std::endl;
    #endif

    std::cout << std::endl;
}

int main() {
    std::cout << "LightGBM Static Library Test" << std::endl;
    std::cout << "=============================" << std::endl << std::endl;

    // Print build information first
    printBuildInfo();

    // Simple example data
    std::vector<double> train_data = {
        1.0, 0.5, 0.3,
        2.0, 0.6, 0.4,
        3.0, 0.7, 0.5,
        4.0, 0.8, 0.6,
        5.0, 0.9, 0.7
    };

    std::vector<float> train_labels = {0.1, 0.2, 0.3, 0.4, 0.5};

    // Dataset parameters
    int num_data = 5;
    int num_features = 3;

    // Create dataset parameters with verbose output to see configuration
    const char* params = "objective=regression metric=l2 num_leaves=10 learning_rate=0.05 feature_fraction=1.0 bagging_fraction=1.0 min_data_in_leaf=1 min_sum_hessian_in_leaf=1.0 num_threads=0 verbosity=1";

    std::cout << "Training Configuration:" << std::endl;
    std::cout << "- num_threads=0 (use all available cores with OpenMP if enabled)" << std::endl;
    std::cout << "- verbosity=1 (show training info)" << std::endl << std::endl;

    DatasetHandle train_dataset;
    BoosterHandle booster;

    // Create dataset
    int result = LGBM_DatasetCreateFromMat(
        train_data.data(),
        C_API_DTYPE_FLOAT64,
        num_data,
        num_features,
        1,  // is_row_major
        params,
        nullptr,
        &train_dataset
    );

    if (result != 0) {
        std::cerr << "Failed to create dataset. Error code: " << result << std::endl;
        return 1;
    }

    // Set labels
    result = LGBM_DatasetSetField(
        train_dataset,
        "label",
        train_labels.data(),
        num_data,
        C_API_DTYPE_FLOAT32
    );

    if (result != 0) {
        std::cerr << "Failed to set labels. Error code: " << result << std::endl;
        LGBM_DatasetFree(train_dataset);
        return 1;
    }

    // Create booster
    result = LGBM_BoosterCreate(
        train_dataset,
        params,
        &booster
    );

    if (result != 0) {
        std::cerr << "Failed to create booster. Error code: " << result << std::endl;
        LGBM_DatasetFree(train_dataset);
        return 1;
    }

    // Train for a few iterations
    int num_iterations = 10;
    for (int i = 0; i < num_iterations; ++i) {
        int is_finished = 0;
        result = LGBM_BoosterUpdateOneIter(booster, &is_finished);
        if (result != 0) {
            std::cerr << "Training failed at iteration " << i << std::endl;
            break;
        }
        if (is_finished) {
            std::cout << "Early stopping at iteration " << i << std::endl;
            break;
        }
    }

    std::cout << "Training completed successfully!" << std::endl;

    // Make predictions on the training data
    int64_t num_predict = 0;
    std::vector<double> predictions(num_data);

    result = LGBM_BoosterPredictForMat(
        booster,
        train_data.data(),
        C_API_DTYPE_FLOAT64,
        num_data,
        num_features,
        1,  // is_row_major
        C_API_PREDICT_NORMAL,
        0,  // start_iteration
        -1, // num_iteration (use all)
        "",  // parameter
        &num_predict,
        predictions.data()
    );

    if (result == 0) {
        std::cout << "\nPredictions:" << std::endl;
        for (int i = 0; i < num_data; ++i) {
            std::cout << "  Sample " << i + 1 << ": "
                     << "Actual = " << train_labels[i]
                     << ", Predicted = " << predictions[i] << std::endl;
        }
    } else {
        std::cerr << "Prediction failed. Error code: " << result << std::endl;
    }

    // Get feature importance
    int num_features_importance = 0;
    result = LGBM_BoosterGetNumFeature(booster, &num_features_importance);
    if (result == 0) {
        std::vector<double> importance(num_features_importance);
        int importance_type = 0; // 0 for split, 1 for gain
        result = LGBM_BoosterFeatureImportance(
            booster,
            -1,  // num_iteration
            importance_type,
            importance.data()
        );

        if (result == 0) {
            std::cout << "\nFeature Importance (splits):" << std::endl;
            for (int i = 0; i < num_features_importance; ++i) {
                std::cout << "  Feature " << i << ": " << importance[i] << std::endl;
            }
        }
    }

    // Cleanup
    LGBM_BoosterFree(booster);
    LGBM_DatasetFree(train_dataset);

    std::cout << "\nLightGBM static library successfully integrated!" << std::endl;

    return 0;
}
