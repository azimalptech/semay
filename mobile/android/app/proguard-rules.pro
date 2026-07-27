# image_cropper's bundled uCrop library has an optional remote-image code path
# (BitmapLoadTask.downloadFile) that references OkHttp. This app only ever crops
# LOCAL files (picked posts/avatars), so OkHttp is never on the classpath and
# that path is never reached — but R8 still sees the references and aborts the
# release build. Suppress the warnings for the unused classes.
-dontwarn okhttp3.**
-dontwarn okio.**
