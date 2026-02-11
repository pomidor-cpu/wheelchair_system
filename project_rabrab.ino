const int ENA = 3;  
const int ENB = 6;   
const int IN1 = 2;  
const int IN2 = 4;
const int IN3 = 5;   
const int IN4 = 7;

const int TRIG_PIN = 8; 
const int ECHO_PIN = 9;
const int OBSTACLE_DISTANCE_CM = 20;

bool isMoving = false; 
bool isStoppedByObstacle = false; 
unsigned long moveStartTime = 0; 
float MOVE_TIME_PER_METER = 1000.0; 
float remainingDistance = 0;
float metersAlreadyPassed = 0;


String input = "";  
bool motorsRunning = false;

void setup() {
  Serial.begin(9600); 
  
 
  pinMode(ENA, OUTPUT);
  pinMode(ENB, OUTPUT);
  pinMode(IN1, OUTPUT);
  pinMode(IN2, OUTPUT);
  pinMode(IN3, OUTPUT);
  pinMode(IN4, OUTPUT);

  pinMode(TRIG_PIN, OUTPUT);
pinMode(ECHO_PIN, INPUT);
  

    stopMotors();
 
  delay(1000);
  Serial.println("System ready");
}

void loop() {
  
  while (Serial.available()) {
    char c = Serial.read();
    
    if (c == '\n') {
      input.trim();
     if (input.length() > 0) {
                parseCommand(input);
            }
      input = "";
    } else if (c != '\r') {
      input += c;
    }
  }
 


    if (isMoving) {
   
    float distanceCm = getSonarDistance();
    
    if (distanceCm > 0 && distanceCm < OBSTACLE_DISTANCE_CM) {
     
      stopMotors();
      isMoving = false;
      isStoppedByObstacle = true;

     
      unsigned long elapsed = millis() - moveStartTime;
      float metersCovered = elapsed / MOVE_TIME_PER_METER;
       metersAlreadyPassed += metersCovered;
      remainingDistance -= metersCovered;
if (remainingDistance < 0) remainingDistance = 0;
      
     
     
      
      Serial.print("LOG;Obstacle detected at: ");
      Serial.print(distanceCm);
      Serial.println("cm");
      
    } else {
      
      unsigned long elapsed = millis() - moveStartTime;
      float metersPassed = elapsed / MOVE_TIME_PER_METER;

if (metersPassed >= remainingDistance) {
  stopMotors();
  isMoving = false;
  remainingDistance = 0;
  metersAlreadyPassed = 0; 
  moveStartTime = 0;  
  Serial.println("N");
}
      
    }
  } 
  
  /
else if (isStoppedByObstacle) { 
    float distanceCm = getSonarDistance();

  
    if (distanceCm > (OBSTACLE_DISTANCE_CM + 10) || distanceCm > 150) {
      
      isStoppedByObstacle = false;
    isMoving = true;
    moveStartTime = millis() - (metersAlreadyPassed * MOVE_TIME_PER_METER);

    bothForward(); 
    }
  }
 
delay(10); 
}
void parseCommand(String command) {
  command.trim();
  

  if (command.startsWith("WP;")) {
    char buf[120];
    command.toCharArray(buf, sizeof(buf));
    
    char *tok = strtok(buf, ";");
    tok = strtok(NULL, ";"); 
    int idx = tok ? atoi(tok) : -1;
    tok = strtok(NULL, ";"); 
    double lat = tok ? atof(tok) : 0.0;
    tok = strtok(NULL, ";");
    double lon = tok ? atof(tok) : 0.0;
    
   
    Serial.print("ACK;WP;");
    Serial.println(idx);
    
  } 
  
  else if (command == "LEFT_FORWARD") {
    leftForward();
    Serial.println("ACK;LEFT_FORWARD");
  } 
  else if (command == "RIGHT_FORWARD") {
    rightForward();
    Serial.println("ACK;RIGHT_FORWARD");
  } 
  else if (command == "BOTH_FORWARD") {
    bothForward();
    Serial.println("ACK;BOTH_FORWARD");
  } 
  else if (command == "STOP") {
    stopMotors();
    Serial.println("ACK;STOP");
  } 
   
  else if (command.startsWith("DIFF:")) {
    float angle = command.substring(5).toFloat();
    handleTurn(angle);
  }


  else if (command.startsWith("DIST:")) {
    float meters = command.substring(5).toFloat();
 
    remainingDistance = meters;
moveStartTime = millis();
isMoving = true;
isStoppedByObstacle = false;
bothForward();
  }

  else {
   
    Serial.print("ERR;unknown;");
    Serial.println(command);
  }
}

float TURN_TIME_PER_DEGREE = 8.2;
 

void handleTurn(float angle) {
  bool turnRight = angle > 0;  
  float absAngle = fabs(angle);

  unsigned long turnTime = absAngle * TURN_TIME_PER_DEGREE;

  Serial.print("LOG;TURN_START;");
  Serial.println(angle);

  if (turnRight) {
 
    rightForward();
  } else {
   
    leftForward();  
  }

  unsigned long start = millis();
  while (millis() - start < turnTime) {
   
  }

  stopMotors();

  Serial.println("ACK;TURN_DONE");
}




void handleMove(float meters) {
    float absDist = fabs(meters);
    
  

    moveStartTime = millis();
    isMoving = true;
    isStoppedByObstacle = false;

    Serial.print("LOG;MOVE_START;");
    Serial.println(meters);

    bothForward();
    
}


float getSonarDistance() {

    digitalWrite(TRIG_PIN, LOW);
    delayMicroseconds(2);
    digitalWrite(TRIG_PIN, HIGH);
    delayMicroseconds(10);
    digitalWrite(TRIG_PIN, LOW);

   
    long duration = pulseIn(ECHO_PIN, HIGH);
    
  
    float distance = duration * 0.034 / 2.0;

    return distance;
}


void leftForward() {
  digitalWrite(IN1, HIGH);
  digitalWrite(IN2, LOW);
  analogWrite(ENA, 200);  
  
  digitalWrite(IN3, LOW);
  digitalWrite(IN4, LOW);
  analogWrite(ENB, 0);  
  
  motorsRunning = true;
}

void rightForward() {
  digitalWrite(IN3, LOW);
  digitalWrite(IN4, HIGH);
  analogWrite(ENB, 200);  
  
  digitalWrite(IN1, LOW);
  digitalWrite(IN2, LOW);
  analogWrite(ENA, 0);  
  
  motorsRunning = true;
}

void bothForward() {
  digitalWrite(IN1, HIGH);
  digitalWrite(IN2, LOW);
  digitalWrite(IN3, LOW);
  digitalWrite(IN4, HIGH);
  analogWrite(ENA, 200);  
  analogWrite(ENB, 200);
  
  motorsRunning = true;
}

void stopMotors() {
  digitalWrite(IN1, LOW);
  digitalWrite(IN2, LOW);
  digitalWrite(IN3, LOW);
  digitalWrite(IN4, LOW);
  analogWrite(ENA, 0);
  analogWrite(ENB, 0);
  
  motorsRunning = false;
}