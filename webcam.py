from flask import Flask, Response
import cv2

app = Flask(__name__)


def open_camera():
    for index in (0, 1, 2, 3):
        cap = cv2.VideoCapture(index)
        if cap.isOpened():
            ret, frame = cap.read()
            if ret and frame is not None:
                return cap, frame
            cap.release()
    return None, None


@app.route('/capture')
def capture():
    cap, frame = open_camera()
    if cap is None or frame is None:
        return "No webcam available on this machine. Check that a camera is connected and not being used by another app.", 500

    try:
        _, buffer = cv2.imencode('.jpg', frame)
        return Response(buffer.tobytes(), mimetype='image/jpeg')
    finally:
        cap.release()


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5011, debug=False)
