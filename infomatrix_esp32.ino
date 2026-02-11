
#include <WiFi.h>
#include <HTTPClient.h>
#include "esp_camera.h"
#include <ArduinoJson.h>
#include "esp_http_server.h"


const char* ssid = "..."; 
const char* password = "123456777"; 
String lastGeminiText = "";


const String apiKey = "AIzaSyBmiLPHZTA1pnY58FCQ2iEbFseJ9v";


const char* prompt = "You are an assistant for a blind person. Analyze the image: describe what you see and check for hazards.Instructions:WARNING: If you see a RED traffic light, a prohibition sign, or an immediate hazard (a pothole, a car directly ahead) - start your response STRICTLY with the word 'STOP'.Describe the surroundings (right, left, front), the main focus, and suggest where the photo was taken.Is there a clear path for a wheelchair? Keep the response concise (maximum 3-4 sentences).";
static esp_err_t last_handler(httpd_req_t *req);


const long apiInterval = 39000; 
unsigned long lastApiCallTime = 0;


httpd_handle_t stream_httpd = NULL;


#define PWDN_GPIO_NUM 32
#define RESET_GPIO_NUM -1
#define XCLK_GPIO_NUM 0
#define SIOD_GPIO_NUM 26
#define SIOC_GPIO_NUM 27
#define Y9_GPIO_NUM 35
#define Y8_GPIO_NUM 34
#define Y7_GPIO_NUM 39
#define Y6_GPIO_NUM 36
#define Y5_GPIO_NUM 21
#define Y4_GPIO_NUM 19
#define Y3_GPIO_NUM 18
#define Y2_GPIO_NUM 5
#define VSYNC_GPIO_NUM 25
#define HREF_GPIO_NUM 23
#define PCLK_GPIO_NUM 22


const char* base64_chars = 
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    "abcdefghijklmnopqrstuvwxyz"
    "0123456789+/";


static esp_err_t stream_handler(httpd_req_t *req) {
  camera_fb_t * fb = NULL;
  esp_err_t res = ESP_OK;
  char part_buf[64];

  static const char* _STREAM_CONTENT_TYPE = "multipart/x-mixed-replace;boundary=frame";
  static const char* _STREAM_BOUNDARY = "\r\n--frame\r\n";
  static const char* _STREAM_PART = "Content-Type: image/jpeg\r\nContent-Length: %u\r\n\r\n";

  res = httpd_resp_set_type(req, _STREAM_CONTENT_TYPE);
  if (res != ESP_OK) {
    return res;
  }

  while (true) {
    fb = esp_camera_fb_get();
    if (!fb) {
      Serial.println("Camera capture failed for stream");
      res = ESP_FAIL;
    } else {
      if (fb->format != PIXFORMAT_JPEG) {
        Serial.println("Non-JPEG frame format");
        res = ESP_FAIL;
      } else {
        res = httpd_resp_send_chunk(req, _STREAM_BOUNDARY, strlen(_STREAM_BOUNDARY));
        if (res == ESP_OK) {
          size_t hlen = snprintf(part_buf, 64, _STREAM_PART, fb->len);
          res = httpd_resp_send_chunk(req, part_buf, hlen);
        }
        if (res == ESP_OK) {
          res = httpd_resp_send_chunk(req, (const char *)fb->buf, fb->len);
        }
      }
      esp_camera_fb_return(fb);
    }
    if (res != ESP_OK) {
      break; 
    }
  }
  return res;
}


static esp_err_t root_handler(httpd_req_t *req) {
  String html = "<html><head><title>ESP32-CAM Stream</title></head>";
  html += "<body style='font-family: Arial, sans-serif; text-align: center; background-color: #f0f0f0;'>";
  html += "<h1>ESP32-CAM Live Stream</h1>";
  
  html += "<img src='/stream' style='width:auto; max-width: 800px; border: 2px solid #333; border-radius: 8px;'>";
  html += "</body></html>";
  
  httpd_resp_set_type(req, "text/html");
  return httpd_resp_send(req, html.c_str(), html.length());
}


void startCameraServer() {
  httpd_config_t config = HTTPD_DEFAULT_CONFIG();
  config.server_port = 80;
  config.ctrl_port = 32768;

  httpd_uri_t stream_uri = {
    .uri       = "/stream",
    .method    = HTTP_GET,
    .handler   = stream_handler,
    .user_ctx  = NULL
  };
  httpd_uri_t root_uri = {
    .uri       = "/",
    .method    = HTTP_GET,
    .handler   = root_handler,
    .user_ctx  = NULL
  };
  httpd_uri_t last_uri = {
    .uri       = "/last",
    .method    = HTTP_GET,
    .handler   = last_handler,
    .user_ctx  = NULL
  };

  Serial.println("Starting HTTP server...");
  esp_err_t err = httpd_start(&stream_httpd, &config);
  Serial.printf("httpd_start result: %d\n", (int)err);

  if (err == ESP_OK) {
    httpd_register_uri_handler(stream_httpd, &root_uri);
    httpd_register_uri_handler(stream_httpd, &stream_uri);
    httpd_register_uri_handler(stream_httpd, &last_uri);
    Serial.println("HTTP server started on port 80");
  } else {
    Serial.println("HTTP server start FAILED!");
    if (err == ESP_ERR_NO_MEM) {
      Serial.println("Reason: not enough memory (ESP_ERR_NO_MEM).");
    }
  }
}

static esp_err_t last_handler(httpd_req_t *req) {

  httpd_resp_set_type(req, "text/plain; charset=utf-8");


  if (lastGeminiText.length() == 0) {
    return httpd_resp_send(req, "NO_DATA_YET", strlen("NO_DATA_YET"));
  }

  return httpd_resp_send(req, lastGeminiText.c_str(), lastGeminiText.length());
}


String encodeImageToBase64(uint8_t* data, size_t length) {
    String base64 = "";
    int i = 0;
    int j = 0;
    uint8_t char_array_3[3];
    uint8_t char_array_4[4];

    while (length--) {
        char_array_3[i++] = *(data++);
        if (i == 3) {
            char_array_4[0] = (char_array_3[0] & 0xfc) >> 2;
            char_array_4[1] = ((char_array_3[0] & 0x03) << 4) + ((char_array_3[1] & 0xf0) >> 4);
            char_array_4[2] = ((char_array_3[1] & 0x0f) << 2) + ((char_array_3[2] & 0xc0) >> 6);
            char_array_4[3] = char_array_3[2] & 0x3f;

            for (i = 0; i < 4; i++)
                base64 += base64_chars[char_array_4[i]];
            i = 0;
        }
    }

    if (i) {
        for (j = i; j < 3; j++)
            char_array_3[j] = '\0';

        char_array_4[0] = (char_array_3[0] & 0xfc) >> 2;
        char_array_4[1] = ((char_array_3[0] & 0x03) << 4) + ((char_array_3[1] & 0xf0) >> 4);
        char_array_4[2] = ((char_array_3[1] & 0x0f) << 2) + ((char_array_3[2] & 0xc0) >> 6);

        for (j = 0; j < i + 1; j++)
            base64 += base64_chars[char_array_4[j]];

        while (i++ < 3)
            base64 += '=';
    }

    return base64;
}

void setup() {
  Serial.begin(115200);
  
  WiFi.begin(ssid, password);
  Serial.println("Connecting to WiFi...");
  
  while (WiFi.status() != WL_CONNECTED) {
    delay(1000);
    Serial.print(".");
  }
  
  Serial.println("\n---------------------------------");
  Serial.println("WiFi connected!");
  Serial.print("Stream available at: http://");
  Serial.println(WiFi.localIP());
  Serial.println("---------------------------------");


  camera_config_t config;
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer = LEDC_TIMER_0;
  config.pin_d0 = Y2_GPIO_NUM;
  config.pin_d1 = Y3_GPIO_NUM;
  config.pin_d2 = Y4_GPIO_NUM;
  config.pin_d3 = Y5_GPIO_NUM;
  config.pin_d4 = Y6_GPIO_NUM;
  config.pin_d5 = Y7_GPIO_NUM;
  config.pin_d6 = Y8_GPIO_NUM;
  config.pin_d7 = Y9_GPIO_NUM;
  config.pin_xclk = XCLK_GPIO_NUM;
  config.pin_pclk = PCLK_GPIO_NUM;
  config.pin_vsync = VSYNC_GPIO_NUM;
  config.pin_href = HREF_GPIO_NUM;
  config.pin_sscb_sda = SIOD_GPIO_NUM;
  config.pin_sscb_scl = SIOC_GPIO_NUM;
  config.pin_pwdn = PWDN_GPIO_NUM;
  config.pin_reset = RESET_GPIO_NUM;
  config.xclk_freq_hz = 20000000;
  config.pixel_format = PIXFORMAT_JPEG;
  config.frame_size = FRAMESIZE_QVGA;
  config.jpeg_quality = 10;
  config.fb_count = 2; 

  if (esp_camera_init(&config) != ESP_OK) {
    Serial.println("Camera init failed");
    return;
  }

  Serial.println("Camera ready.");
  

  startCameraServer();
}



void captureAndAnalyzeImage() {
  Serial.println("Taking photo for AI...");
  

  camera_fb_t* fb = esp_camera_fb_get(); 
  if (!fb) {
    Serial.println("Camera capture failed");
    return;
  }

  Serial.println("Image captured, encoding...");
  
  
  String base64Image = encodeImageToBase64(fb->buf, fb->len);

  
  esp_camera_fb_return(fb); 

  if (base64Image.isEmpty() || base64Image.length() < 100) {
    Serial.println("Failed to encode the image!");
    return;
  }
  
  Serial.println("Encoding OK. Sending to Gemini...");

  AnalyzeImage(base64Image);
}

void AnalyzeImage(const String& base64Image) {
  Serial.println("Sending image for analysis...");

  String result;
  

  DynamicJsonDocument doc(8192); 
  JsonArray contents = doc.createNestedArray("contents");
  JsonObject content = contents.createNestedObject();
  JsonArray parts = content.createNestedArray("parts");
  
  
  JsonObject textPart = parts.createNestedObject();
  textPart["text"] = prompt;
  
 
  JsonObject imagePart = parts.createNestedObject();
  JsonObject inlineData = imagePart.createNestedObject("inlineData");
  inlineData["mimeType"] = "image/jpeg";
  

  inlineData["data"] = base64Image;
  

  JsonObject genConfig = doc.createNestedObject("generationConfig");
  genConfig["maxOutputTokens"] = 400;

  String jsonPayload;
  serializeJson(doc, jsonPayload);


  if (jsonPayload.length() == 0) {
      Serial.println("Failed to serialize JSON. Payload is empty.");
      return;
  }
  
 
  if (sendPostRequest(jsonPayload, result)) {
    Serial.println("[Gemini] Raw Response: " + result);

    DynamicJsonDocument responseDoc(4096);
    deserializeJson(responseDoc, result);

    String responseContent = responseDoc["candidates"][0]["content"]["parts"][0]["text"].as<String>();
    
    Serial.println("---------------------------------");
    Serial.println("[Gemini] Got response:");
    Serial.println(responseContent);
    lastGeminiText = responseContent;

    Serial.println("---------------------------------");

  } else {
    Serial.println("[Gemini] Error: " + result);
  }
}

bool sendPostRequest(const String& payload, String& result) {
  HTTPClient http;
  
  String apiUrl = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=" + apiKey;
  
  http.begin(apiUrl);
  http.addHeader("Content-Type", "application/json");
  http.setTimeout(30000); 

  Serial.print("Payload size: ");
  Serial.println(payload.length());

  int httpResponseCode = http.POST(payload);

  if (httpResponseCode > 0) {
    result = http.getString();
    http.end();
    return true;
  } else {
    result = "HTTP request failed, response code: " + String(httpResponseCode) + " | " + http.errorToString(httpResponseCode);
    http.end();
    return false;
  }
}


void loop() {
  
  unsigned long currentTime = millis();
  if (currentTime - lastApiCallTime >= apiInterval) {
    lastApiCallTime = currentTime;

   
    if (WiFi.status() == WL_CONNECTED) {
      Serial.println("\n[Timer] 60s interval reached. Starting capture...");
      captureAndAnalyzeImage();
    } else {
      Serial.println("\n[Timer] 60s interval reached, but WiFi is disconnected. Skipping.");
    }
  }
  
  
  delay(10); 
}
