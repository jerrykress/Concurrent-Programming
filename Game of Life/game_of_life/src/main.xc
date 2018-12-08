// COMS20001 - Cellular Automaton Farm - Initial Code Skeleton
// (using the XMOS i2c accelerometer demo code)

#include <platform.h>
#include <xs1.h>
#include <stdio.h>
#include <math.h>
#include "pgmIO.h"
#include "i2c.h"

#define  IMHT 1032                   //image height
#define  IMWD 1032                  //image width
#define  WKNB 8                  //number of workers

#define FILEINNAME ("1032x1032.pgm")
#define FILEOUTNAME ("testout.pgm")

typedef unsigned char uchar;      //using uchar as shorthand

on tile[0]: port p_scl = XS1_PORT_1E;         //interface ports to orientation
on tile[0]: port p_sda = XS1_PORT_1F;

#define FXOS8700EQ_I2C_ADDR 0x1E  //register addresses for orientation
#define FXOS8700EQ_XYZ_DATA_CFG_REG 0x0E
#define FXOS8700EQ_CTRL_REG_1 0x2A
#define FXOS8700EQ_DR_STATUS 0x0
#define FXOS8700EQ_OUT_X_MSB 0x1
#define FXOS8700EQ_OUT_X_LSB 0x2
#define FXOS8700EQ_OUT_Y_MSB 0x3
#define FXOS8700EQ_OUT_Y_LSB 0x4
#define FXOS8700EQ_OUT_Z_MSB 0x5
#define FXOS8700EQ_OUT_Z_LSB 0x6

on tile[0] : in port buttons = XS1_PORT_4E; //port to access xCore-200 buttons
on tile[0] : out port leds = XS1_PORT_4F;   //port to access xCore-200 LEDs

/////////////////////////////////////////////////////////////////////////////////////////
//
// Start your implementation by changing this function to implement the game of life
// by farming out parts of the image to worker threads who implement it...
// Currently the function just inverts the image
//
/////////////////////////////////////////////////////////////////////////////////////////
void distributor(in port p_button, out port p, chanend fromAcc, chanend toWorker[WKNB]){
      int res;
      uchar line[ IMWD ], packedByte;
      int r = 0, round = 0, liveCount = 0, tilted = 2, notPrinted = 1;
      uchar originalWorld[ IMHT ][ IMWD / 8 ];
      timer t;
      unsigned int start, end;
      const unsigned int conversion = 100; // conversion from nanosec to microsec
      unsigned long long int totalTime = 0, roundTime, totalGameLogicTime = 0;
      int pattern = 0; //1st bit...separate green LED
                            //2nd bit...blue LED
                            //3rd bit...green LED
                            //4th bit...red LED


  ////////////////////////////////////////////////////////////
  /////      Here is the original DataInStream       /////////
  ///////////////////////////////////////////////////////////


  //Starting up and wait for tilting of the xCore-200 Explorer
  printf( "ProcessImage: Start, size = %dx%d\n", IMHT, IMWD );
  printf( "Waiting for SW1 button (left) to be pressed...\n" );
  //  fromAcc :> int value;

   while (r != 14) {
       p_button when pinsneq(15) :> r;    // check if some buttons are pressed
       if (r==14) {     // if either button is pressed

           //Game starts
           printf( "Processing...\n" );


           //Indicate Green LED for reading
           pattern = pattern ^ 4;
           p <: pattern;             //send pattern directly to LED port
           printf( "DataInStream: Start...\n" );

            //Open PGM file
            res = _openinpgm( FILEINNAME, IMWD, IMHT );
            if( res ) {
              printf( "DataInStream: Error openening %s\n.", FILEINNAME );
             return;
            }

            //Read image line-by-line and send byte by byte to channel c_out
              for( int y = 0; y < IMHT; y++ ) {
                _readinline( line, IMWD );
                int counter = 0, shifter = 7;
                packedByte = 0;
                for( int x = 0; x < IMWD; x++ ) {
                // Bit packing
                if (line[x] == 255) liveCount++;
                if (counter < 8) {
                      packedByte = packedByte | (( line[ x ] & 0x01 ) << shifter);
                      shifter--;
                      counter++;
                  }
                  if (counter == 8){
                      originalWorld[y][x / 8] = packedByte;
                      //printf( "DEBUG_LOG: -%4.1X ", packedByte ); //DEBUG_LOG: show image values
                      counter = 0;
                      shifter = 7;
                      packedByte = 0;
                  }

                }
              //printf( "\n" );
              }
              //Close PGM image file
              _closeinpgm();
              printf( "DataInStream: Done...\n" );

              printf("\nThe live count is: %d\n", liveCount);
       }
   }

   //Indicate Green LED for reading done
   pattern = pattern ^ 4;
   p <: pattern; //send pattern to LED port


   ////////////////////////////////////////////////////////////
   /////      Here is the distribution Process        /////////
   ///////////////////////////////////////////////////////////


           while (1){
               fromAcc :> tilted; //Get orientation

               if (!tilted && round < 100) { //Proceed if board is not tilted
                   t :> start;
                   if (!notPrinted) {
                       pattern = pattern ^ 8; //Turn off red LED when board returns to level and game continues
                       p <: pattern; //send pattern to LED port
                   }
                   round++;
                   notPrinted = 1;

                   //Indicate LEDs that process has started(turn Green LED on only
                   //on odd rounds
                   pattern = pattern ^ 1;
                   p <: pattern; //send pattern to LED port

               liveCount = 0; //Reset live cell count


               ///////////////SENDING TO WORKER//////////////
               for (int n = 0 ; n < WKNB ; n++) { //For each worker
                   int start = n * ceil(IMHT / WKNB) - 1; //Calculate Start row number. Round up to an Int
                   int finish = (n + 1) * ceil(IMHT / WKNB); //Calculate End row number. Round up to an Int
                   if (n == WKNB - 1) { //If this is the last worker
                       finish = IMHT; //Limit its Lower bound to the last row of image
                       toWorker[n] <: 1; //Signal worker it's receiveing a smaller worker map
                   } else {
                       toWorker[n] <: 0; //Else signal worker it's receving a standard worker map
                   }
                   for (int y = start ; y <= finish ; y++) { //Officially sending map to this worker
                       int mappedY = y;
                       for (int x = 0 ; x < IMWD / 8 ; x++) {//Wrapped map logic or edge case
                           if (y == -1) mappedY = IMHT - 1;  //If the upper row does not exist, set to last row
                           else if (y == IMHT) mappedY = 0;  //If the lower row does not exist, set to first row
                           toWorker[n] <: originalWorld[mappedY][x]; //Send this packed byte
                       }
                   }
               }

               int workerLiveCount; //Sum of worker live cell counts
               unsigned int workerTime;
               unsigned int roundGameLogicTime = 0;
               uchar receivedByte;

               ///////////////////RECEIVING FROM WORKER/////////////////
               for (int n = 0 ; n < WKNB ; n++) {
                   int start = n * ceil(IMHT / WKNB);
                   int finish;
                   if (n == WKNB - 1) {
                       finish = IMHT - 1;
                   } else {
                       finish = (n + 1) * ceil(IMHT / WKNB) - 1;
                   }
                   for (int y = start ; y <= finish ; y++) {
                       for (int x = 0 ; x < IMWD / 8 ; x++) {
                           toWorker[n] :> receivedByte;
                           originalWorld[y][x] = receivedByte;
                       }
                   }
                   toWorker[n] :> workerLiveCount;
                   liveCount += workerLiveCount;
                   toWorker[n] :> workerTime;
                   if (roundGameLogicTime < workerTime) {
                       roundGameLogicTime = workerTime;
                   }
               }

//               printf("The round's game logic time is: %u\n", roundGameLogicTime);

               totalGameLogicTime += roundGameLogicTime;

                 //Check for SW2 button being pressed
                 // Idea got from XMOS docs
                 int current_val = 14;


//                 printf( "Round no. %d completed...\n", round );

                 t :> end; //Receive end time from timer and check overflow
                 if (end < start) { //If the end time is smaller than start time then the timer has overflown
                     roundTime = (end + (UINT_MAX - start)) / conversion; //Amend the overflown value
                 } else {
                     roundTime = (end - start) / conversion; //Else the timer is not overflow, add the new time to total time
                 }

                 totalTime += roundTime;

//                 printf("COMPARISON: The round time is: %llu microsec and the game logic time is: %llu\n", roundTime, totalGameLogicTime);
                 printf("Number of live cells: %d\n", liveCount);

                 ////////////////////////////////////////////////////////////
                 /////      Here is the original DataOutStream       ////////
                 ////////////////////////////////////////////////////////////

                     select{
                         // event when the button changes value
                         case p_button when pinsneq(current_val) :> int new_val:
                             if (new_val == 13) {
                                 //Indicate LEDs that the wirting process has started
                                 pattern = pattern ^ 2;
                                 p <: pattern;                //send pattern to LED port

                                 //Open PGM file
                                  printf( "DataOutStream: Start...\n" );
                                 res = _openoutpgm( FILEOUTNAME, IMWD, IMHT );

                                 if( res ) {
                                     printf( "DataOutStream: Error opening %s\n.", FILEOUTNAME );
                                     return;
                                   }

                                 //Compile each line of the image and write the image line-by-line
                                 for( int y = 0; y < IMHT; y++ ) {
                                     int shifter = 7, counter = 0;
                                     for( int x = 0; x < IMWD / 8; x++ ) {
                                       while (counter < 8) {
                                           packedByte = originalWorld[y][x];
                                           /////////UNPACKING FOR PRINT///////
                                           if (((packedByte >> shifter) & 0x01) == 1) {
                                               line[ x * 8 + 7 - shifter ]  = 255;
                                           } else {
                                               line[ x * 8 + 7 - shifter ]  = 0;
                                           }
                                           shifter--;
                                           counter++;
                                           }
                                       if (counter == 8) {
                                           shifter = 7;
                                           counter = 0;
                                       }
                                     }
                                     _writeoutline( line, IMWD );
//                                     printf( "DataOutStream: Line written...\n" );
                                   }
                                  //Close the PGM image
                                  _closeoutpgm();
                                  printf( "DataOutStream: Done...\n" );


                                 //Indicate LEDs that the wirting process has ended
                                 pattern = pattern ^ 2;
                                 p <: pattern; //send pattern to LED port
                             } else {
                                 break;
                             }
                             break;
                     }

               } else { //If board is tilted and game is paused, proceed to printing the report
                   if (notPrinted) { //If the report has not been printed once, do print
                       pattern = pattern ^ 8;
                       p <: pattern;                //send pattern to LED port
                       printf("\n\n=====================================\n PRINTING PAUSE REPORT \n====================================\n");
                       printf("Current round: %d\n", round);
                       printf("Current number of live cells: %d\n", liveCount);
                       printf("Processing time elapsed: %llu microsec \n\n", totalTime);
                       printf("Game logic time elapsed: %llu microsec \n\n", totalGameLogicTime);
                       notPrinted = 0; //Change notPrinted flag to 0
                   } //If the report has been printed once, do nothing
               }

           }
}


////////////////////////////////////////////////////////////
//////////      Here is the worker logic       /////////////
////////////////////////////////////////////////////////////
void worker(chanend fromDistributor) {
    uchar originalWorld[ IMHT / WKNB + 3 ][ IMWD / 8 ], copyWorld[ IMHT / WKNB + 3 ][ IMWD / 8 ];
    uchar val;
    int incomplete, receivingEnd;
    timer workerT;
    unsigned int gameLogicStart, gameLogicEnd;
    const unsigned int conversion = 100; // conversion of 1 microsec
    unsigned int workerLogicTime;

    while(1) {
        int liveCount = 0;

        fromDistributor :> incomplete; //Receive signal from distributor if this worker is processing a smaller map
        if (!incomplete) { //If it is process a smaller map
            receivingEnd = ceil(IMHT / WKNB) + 2; //Calculate the lower bound of the worker map size
        } else {
            receivingEnd = IMHT - (ceil(IMHT / WKNB))*(WKNB-1)  + 2; //Else receive as normal
        }
        //Receive Byte from distributor
        for (int y = 0 ; y < receivingEnd ; y++) {
            for (int x = 0 ; x < IMWD / 8 ; x++) {
                fromDistributor :> val;
                originalWorld[y][x] = val;
                copyWorld[y][x] = val;
                int i = 0;
                if (y != 0 && y != (receivingEnd - 1)) {
                    while (i < 8) {
                        //Processing bit by bit and counting live cells
                        uchar bit = ( val >> i ) & 0x01;
                        if (bit == 1) liveCount++;
                        i++;
                        }
                }

            }
        }

        int endOfStrip = receivingEnd - 1;

        ////////////////////////////////////////////////////////////
        /////      Here is the evolution logic       //////////////
        ///////////////////////////////////////////////////////////

        workerT :> gameLogicStart;

        for (int y = 1 ; y < endOfStrip ; y++) {
            for (int x = 0 ; x < IMWD / 8 ; x++) {
                //printf("++++++++worker processing++++++\n");

                //Incorporate logic for neighbour checking here
                int shift = 7, leftShift, rightShift, leftX, rightX, upY, downY;
                while (shift >= 0) {
                    int aliveNeighbours = 0;
                    leftShift = shift + 1;
                    rightShift = shift - 1;
                    leftX = x;
                    rightX = x;
                    upY = y - 1;
                    downY = y + 1;
                    if (shift == 7) {
                        leftShift = 0;
                        if (x == 0) { //If there is no left Byte, set to most right Byte
                            leftX = IMWD / 8 - 1;
                        } else { //Else set left Byte as normal
                            leftX = x - 1;
                        }
                    } else if (shift == 0) {
                        rightShift = 7;
                        if (x == IMWD / 8 - 1) { //If there is no right Byte, set to most left Byte
                            rightX = 0;
                        } else { //Else set right Byte as normal
                            rightX = x + 1;
                        }
                    }
                    //Left
                    if (((copyWorld[y][leftX] >> leftShift) & 0x01) == 1) aliveNeighbours++;
                    //Left-Up
                    if (((copyWorld[upY][leftX] >> leftShift) & 0x01) == 1) aliveNeighbours++;
                    //Up
                    if (((copyWorld[upY][x] >> shift) & 0x01) == 1) aliveNeighbours++;
                    //Right-Up
                    if (((copyWorld[upY][rightX] >> rightShift) & 0x01) == 1) aliveNeighbours++;
                    //Right
                    if (((copyWorld[y][rightX] >> rightShift) & 0x01) == 1) aliveNeighbours++;
                    //Right-Down
                    if (((copyWorld[downY][rightX] >> rightShift) & 0x01) == 1) aliveNeighbours++;
                    //Down
                    if (((copyWorld[downY][x] >> shift) & 0x01) == 1) aliveNeighbours++;
                    //Left-Down
                    if (((copyWorld[downY][leftX] >> leftShift) & 0x01) == 1) aliveNeighbours++;

                    //Game logic
                    if (aliveNeighbours < 2 || aliveNeighbours > 3) {
                        if (((originalWorld[y][x] >> shift) & 0x01) == 1) liveCount--;
                        originalWorld[y][x] = originalWorld[y][x] & ((0xFF << (shift + 1)) | (0xFF >> (8 - shift)));
                    } else if (((originalWorld[y][x] >> shift) & 0x01) == 0 && aliveNeighbours == 3) {
                        originalWorld[y][x] = originalWorld[y][x] | (0x01 << shift);
                        liveCount++;
                    }

                    shift--;
                }
            }
        }

        workerT :> gameLogicEnd;

        if (gameLogicEnd < gameLogicStart) {
            workerLogicTime = (gameLogicEnd + (UINT_MAX - gameLogicStart)) / conversion;
        } else {
            workerLogicTime = (gameLogicEnd - gameLogicStart) / conversion;
        }

        ////////SENDING BACK NEW MAP TO DISTRIBUTOR/////////
        for (int y = 1 ; y < endOfStrip ; y++) {
            for (int x = 0 ; x < IMWD / 8 ; x++) {
                fromDistributor <: originalWorld[y][x];
            }
        }
        /////////SENDING BACK LIVE COUNT TO DISTRIBUTOR/////////
        fromDistributor <: liveCount;

        fromDistributor <: workerLogicTime;

    }
}



/////////////////////////////////////////////////////////////////////////////////////////
//
// Initialise and  read orientation, send first tilt event to channel
//
/////////////////////////////////////////////////////////////////////////////////////////
void orientation( client interface i2c_master_if i2c, chanend toDist) {
  i2c_regop_res_t result;
  char status_data = 0;

  // Configure FXOS8700EQ
  result = i2c.write_reg(FXOS8700EQ_I2C_ADDR, FXOS8700EQ_XYZ_DATA_CFG_REG, 0x01);
  if (result != I2C_REGOP_SUCCESS) {
    printf("I2C write reg failed\n");
  }
  
  // Enable FXOS8700EQ
  result = i2c.write_reg(FXOS8700EQ_I2C_ADDR, FXOS8700EQ_CTRL_REG_1, 0x01);
  if (result != I2C_REGOP_SUCCESS) {
    printf("I2C write reg failed\n");
  }

  //Probe the orientation x-axis forever
  while (1) {

    //check until new orientation data is available
    do {
      status_data = i2c.read_reg(FXOS8700EQ_I2C_ADDR, FXOS8700EQ_DR_STATUS, result);
    } while (!status_data & 0x08);

    //get new x-axis tilt value
    int x = read_acceleration(i2c, FXOS8700EQ_OUT_X_MSB);

    //send signal to distributor after first tilt
    if(x <= 30) toDist <: 0; //SEND 0 FOR NOT TILT
    else toDist <: 1; //SEND 1 WHEN TILT
  }
}

/////////////////////////////////////////////////////////////////////////////////////////
//
// Orchestrate concurrent system and start up all threads
//
/////////////////////////////////////////////////////////////////////////////////////////
int main(void) {

i2c_master_if i2c[1];               //interface to orientation

chan c_control, c_toWorker[WKNB];    //extend your channel definitions here

par {
    on tile[0]: i2c_master(i2c, 1, p_scl, p_sda, 10);   //server thread providing orientation data
    on tile[0]: orientation(i2c[0],c_control);        //client thread reading orientation data
    on tile[0]: distributor(buttons, leds, c_control, c_toWorker);//thread to coordinate work on image
    on tile[0]: worker(c_toWorker[0]);
    on tile[0]: worker(c_toWorker[1]);
    on tile[1]: worker(c_toWorker[2]);
    on tile[1]: worker(c_toWorker[3]);
    on tile[1]: worker(c_toWorker[4]);
    on tile[1]: worker(c_toWorker[5]);
    on tile[1]: worker(c_toWorker[6]);
    on tile[1]: worker(c_toWorker[7]);
  }

  return 0;
}
